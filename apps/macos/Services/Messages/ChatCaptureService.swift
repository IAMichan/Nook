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

    @Published private(set) var inbox: ChatInbox {
        didSet { inboxRevision &+= 1 }
    }
    /// Goes up with every change of `inbox`, once the change is in. What is made from the inbox and kept (the Chats
    /// tab's list) checks it: `objectWillChange` comes before the change, and a list made again in that moment holds
    /// the chats as they were (a row with yesterday's line under a chat that wrote today).
    private(set) var inboxRevision = 0
    @Published private(set) var status: Status = .off
    /// Which apps feed the inbox (Settings › Connections): the known ones you did not switch off, and the ones you added.
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
    /// What Nook's badges count, the same for every app: the unread messages of the chats that show, except in chats
    /// the notice rules keep out (muted, quiet by their kind and not naming you).
    var visibleUnread: Int {
        let rules = ChatNoticeRulesStore.shared.rules
        return inbox.threads.values.reduce(0) { total, thread in
            thread.unread > 0 && isShown(thread) && rules.isVisible(thread) ? total + thread.unread : total
        }
    }

    /// Chats someone just wrote in (their keys in `inbox`), newest last: Nook may tell you (Settings › Notifications).
    /// Only chats that show and that the notice rules let reach you (`ChatNoticeRules`).
    var onFresh: ([String]) -> Void = { _ in }
    /// Chats read in their own app (on the phone, in the app on this Mac) since Nook last read them: what Nook still had
    /// waiting for them goes.
    var onReadElsewhere: ([String]) -> Void = { _ in }
    /// The chats on screen or waiting in line as a card (their keys in `inbox`): their apps are read quickly meanwhile,
    /// so a card follows its chat as fast for every app as WhatsApp's linked phone brings it.
    var watching: () -> Set<String> = { [] }
    /// The chat open in the Chats tab (its key in `inbox`), nil while none is: its app is read as quickly as a card's,
    /// so a message in the chat you are reading shows within seconds, also from an app read once a minute otherwise.
    /// Not published: it changes what is read, not what is drawn.
    var openChat: String?
    /// Only a message this recent is news; older ones that come in (a first look, a long sleep) are for the Chats tab.
    static let newsWindow: TimeInterval = 600

    /// The apps Nook reads itself, with their history (`ChatBridge`): Messages from this Mac, Slack with a token,
    /// Telegram through TDLib once you logged in, Teams through Microsoft Graph once you signed in, Instagram through its
    /// own web API once you logged in on it inside Nook, Snapchat from its website once you signed in on it inside Nook,
    /// and every mail account in the Mail app once you linked Mail.
    let messagesBridge = MessagesBridge()
    let slackBridge = SlackBridge()
    let telegramBridge = TelegramBridge()
    let teamsBridge = TeamsBridge()
    let snapchatBridge = SnapchatBridge()
    let mailBridge = MailBridge()
    /// WhatsApp from the WhatsApp app on this Mac while no phone is linked, and every app linked through Nook's own chat
    /// helper.
    let whatsAppDesktopBridge = WhatsAppDesktopBridge()
    /// WhatsApp through the linked phone (its gateway), every linked account.
    let whatsAppGatewayBridge = WhatsAppGatewayBridge()
    let serviceBridge = ChatServiceBridge()
    /// The chat helper goes last: an app another bridge reads is left to that one.
    private var bridges: [ChatBridge] {
        [messagesBridge, whatsAppGatewayBridge, whatsAppDesktopBridge, slackBridge, telegramBridge, teamsBridge, snapchatBridge,
         mailBridge, serviceBridge]
    }

    /// Whether a chat shows in Nook (the Chats tab, cards, search, the companion, what Nook reads), the same rule for
    /// every app: its app is on, and you did not hide it. WhatsApp comes from one place at a time: a linked phone's chat
    /// shows while its account is linked, and WhatsApp from anywhere else stands aside meanwhile, or each chat would
    /// show twice.
    func isShown(_ thread: InboxThread) -> Bool {
        guard !ChatNoticeRulesStore.shared.rules.isHidden(thread.id) else { return false }
        if thread.app == whatsAppGatewayBridge.app {
            if let key = thread.chatID { return whatsAppGatewayBridge.isListed(key) }
            if whatsAppGatewayBridge.holdsChats { return false }
        }
        return sources.isOn(thread.app)
    }

    // MARK: Search everything

    /// The bridges that search their app's whole history now (`ChatSearchBridge`): ready, and their app switched on.
    var historySearchers: [any ChatSearchBridge] {
        let archive: [any ChatSearchBridge] = ChatArchiveSearch.shared.searchesHistory ? [ChatArchiveSearch.shared] : []
        return archive + bridges.compactMap { $0 as? any ChatSearchBridge }.filter { bridge in
            bridge.searchesHistory && (bridge.alwaysOn || sources.isOn(bridge.app))
        }
    }

    /// The chat Nook shows for one a history search found, the same rule for every app: the chat with its key, else
    /// the shown chat of its app with the same name (WhatsApp on this Mac while a linked phone brings WhatsApp), else
    /// the chat as found, for one older than what the inbox keeps. Nil for a chat you hid or whose app is off.
    func shownThread(for chat: BridgedChat) -> InboxThread? {
        let threads = loadedInbox.threads
        let key = ChatInbox.key(of: chat)
        if let thread = threads[key] { return isShown(thread) ? thread : nil }
        let named = ChatInbox.key(app: chat.app, chat: chat.name)
        if let thread = threads.values.first(where: { $0.app == chat.app && ChatInbox.key(app: $0.app, chat: $0.name) == named && isShown($0) }) {
            return thread
        }
        var thread = InboxThread(id: key, app: chat.app, name: chat.name)
        thread.chatID = chat.chatID
        thread.account = chat.account
        thread.avatar = chat.avatar
        thread.members = chat.members
        thread.faces = chat.faces
        return isShown(thread) ? thread : nil
    }

    /// You logged in to an app from its row in Settings › Connections: it is switched on, collecting with it, and read now.
    func loggedIn(_ app: String) {
        setSource(app, on: true)
        if !enabled { enabled = true }
        bridgeChanged(app)
    }

    /// The bridge of an app, if Nook has one: the one that reads it now when two can (WhatsApp on this Mac, and through
    /// the linked phone).
    func bridge(for app: String) -> ChatBridge? {
        bridges.first { $0.app == app && $0.isReady } ?? bridges.first { $0.app == app }
    }

    /// A bridge's sign-in changed (Telegram logged in, Teams signed in): read it now instead of at its next turn.
    func bridgeChanged(_ app: String) {
        for bridge in bridges where bridge.app == app {
            bridgeDue[bridge.bridgeID] = nil
            bridgeFailures[bridge.bridgeID] = nil
        }
        bridged.remove(app)
        bridgeProblems[app] = nil
        bridgeSignedOut.remove(app)
        Task { await pollBridges() }
    }
    /// Why a bridge could not read, per app; empty while all of them work.
    @Published private(set) var bridgeProblems: [String: String] = [:]
    /// The apps whose last read failed because the sign-in is gone (`ConnectorErrorKind.auth`): only signing in again
    /// helps, and Settings offers it for every app the same way (`ChatAccountHealth`).
    @Published private(set) var bridgeSignedOut: Set<String> = []
    /// The apps whose bridge read at least once: their chats come in with history, not only from notifications.
    @Published private(set) var bridged: Set<String> = []
    /// Chats the helper has nothing older of (scrolled back to their start).
    private var noOlder: Set<String> = []
    /// The inbox as it was last handed to the archive (`ChatArchive`): each save writes only what changed since.
    private var lastSaved: ChatInbox?
    /// When each chat's oldest stored message is: scrolling back reads from the archive before asking its app.
    private var oldestStored: [String: Date] = [:]
    private var archiveUpkeep: Timer?
    private var backfillTimer: Timer?
    /// A backfill batch is underway: one at a time.
    private var backfilling = false
    /// Each chat's walk back through its history underway (`ChatBackfill.Walk`), and when its last one ended.
    private var walks: [String: ChatBackfill.Walk] = [:]
    private var walkedAt: [String: Date] = [:]
    /// When each app may be asked for its next batch.
    private var backfillDue: [String: Date] = [:]
    /// When each chat was last asked.
    private var backfillAsked: [String: Date] = [:]
    /// When each app last had live traffic (a notification, a read that brought something, a chat you opened): its
    /// backfill waits `ChatBackfill.liveQuiet` after it.
    private var liveAt: [String: Date] = [:]
    /// The free disk space as last looked at, and when (`ChatBackfill.diskCheck`).
    private var freeBytes: (bytes: Int64?, at: Date)?
    /// Chats whose stretch scrolled back to from the archive is being laid beside their app's (`checkStored`).
    private var checking: Set<String> = []
    private var bridgeDue: [String: Date] = [:]
    /// Quick reads still owed to a bridge after one of its app's notifications: the app's own server can list the
    /// message a few seconds (sometimes much longer) after it notified, so it reads again until the message is there.
    private var catchUp = ChatCatchUp()
    /// Reads in a row that failed, per app: each one waits longer before the next try (`ChatBackoff`).
    private var bridgeFailures: [String: Int] = [:]

    /// How often the database is looked at. Only a database that changed is read, so looking is cheap; looking often
    /// matters because Slack and Teams take a notification back as soon as you read the message elsewhere.
    private static let interval: TimeInterval = 1
    /// With the displays asleep nobody reads a notification that was taken back.
    private static let asleepInterval: TimeInterval = 15
    /// A first start shows what came in this long ago: macOS keeps the notifications it showed for a while, so the
    /// chats of the last weeks are there at once instead of only the ones that write after switching on.
    private static let firstLook: TimeInterval = 14 * 86_400
    /// What came in before this long ago, on a first start, counts as read: it was likely seen on the Mac already.
    private static let freshness: TimeInterval = 3600

    private nonisolated static var file: URL { NookPaths.supportDirectory.appendingPathComponent("chat-inbox.json") }
    private var timer: Timer?
    private var planWatch: AnyCancellable?
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
        // Read in the background (`chat-inbox.json` holds weeks of messages): the inbox is empty until it is in.
        inbox = ChatInbox()
        enabled = ConnectorToggle.isOn(ChatInboxConnector.sourceID, default: false)
        serviceBridge.skips = { [weak self] app in
            guard let self else { return false }
            return self.bridges.contains { $0.app == app && $0.isReady && $0.isWorking && $0 !== self.serviceBridge }
        }
        // A chat changed there this moment (its live line said so): read it at the next tick, not at its next turn.
        serviceBridge.onChange = { [weak self] in
            guard let self else { return }
            self.bridgeDue[self.serviceBridge.app] = nil
        }
        // A change from the last moment before quitting is still written.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave(wait: true) }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let read = Self.readInbox()
            await self?.finishLoading(read)
        }
    }

    /// Whether `chat-inbox.json` is read. Every change to the inbox starts with `ensureLoaded`, and nothing is written
    /// before, so a change made from an empty inbox never replaces the chats on disk.
    private var loaded = false

    /// What launch reads: the inbox (each chat with its newest messages), the inbox as it is written (what the first
    /// save compares with), and when each chat's oldest stored message is.
    private struct Loaded: Sendable {
        var inbox: ChatInbox
        var saved: ChatInbox?
        var oldest: [String: Date]
    }

    /// From the archive, after bringing over `chat-inbox.json` once (kept beside it as `chat-inbox.imported.json`).
    /// Without the archive, the JSON file as before.
    private nonisolated static func readInbox() -> Loaded {
        guard let archive = ChatArchive.shared else {
            var inbox = SafeStorage.load(ChatInbox.self, from: file).value ?? ChatInbox()
            inbox.renameMessageIDs()
            inbox.trim()
            return Loaded(inbox: inbox, saved: nil, oldest: [:])
        }
        return archive.writeNow { store in
            if store.state("inbox") == nil, let legacy = SafeStorage.load(ChatInbox.self, from: file).value {
                var inbox = legacy
                inbox.renameMessageIDs()
                if store.apply(from: nil, to: inbox) {
                    try? FileManager.default.moveItem(at: file, to: importedFile)
                    Log.connectors.info("Chats: brought \(inbox.threads.count) chats over into the archive")
                }
            }
            guard let (stored, oldest) = store.loadInbox(window: ChatInbox.keep) else {
                // Nothing written yet, or bringing the file over failed: the file as it is, written in full at the first save.
                var inbox = SafeStorage.load(ChatInbox.self, from: file).value ?? ChatInbox()
                inbox.renameMessageIDs()
                inbox.trim()
                return Loaded(inbox: inbox, saved: nil, oldest: [:])
            }
            var inbox = stored
            inbox.renameMessageIDs()
            inbox.trim()
            return Loaded(inbox: inbox, saved: stored, oldest: oldest)
        }
    }

    private nonisolated static var importedFile: URL { NookPaths.supportDirectory.appendingPathComponent("chat-inbox.imported.json") }

    private func finishLoading(_ read: Loaded) {
        guard !loaded else { return }
        loaded = true
        inbox = read.inbox
        lastSaved = read.saved
        oldestStored = read.oldest
        // What launch tidied (`ChatInbox.trim`) is written: chats that left, messages that went.
        if read.saved != read.inbox { save() }
        startArchiveUpkeep()
        startBackfill()
        if startWhenLoaded {
            startWhenLoaded = false
            start()
        }
    }

    /// Every hour while Nook runs: the archive gives free room back to the disk and tidies its index (`ChatStore.maintain`),
    /// and the fetched files stay within their limit (`ChatMedia.trimAll`).
    private func startArchiveUpkeep() {
        guard let archive = ChatArchive.shared, archiveUpkeep == nil else { return }
        let upkeep: @Sendable () -> Void = {
            archive.write { $0.maintain() }
            // The files every bridge fetched, together: what nobody opened for the longest goes first.
            DispatchQueue.global(qos: .background).async { ChatMedia.trimAll() }
        }
        upkeep()
        archiveUpkeep = Timer.scheduledCoalesced(withTimeInterval: 3600) { _ in upkeep() }
    }

    /// `start` came before the inbox was read.
    private var startWhenLoaded = false

    /// The inbox for something that reads it once and acts on it (a tool of the brain, a search, sending a reply): read
    /// right now when the background read is not done yet, so it never finds the empty inbox of the first moment after
    /// launch. Views read `inbox`, which redraws them once it is in.
    var loadedInbox: ChatInbox {
        ensureLoaded()
        return inbox
    }

    /// Reads the inbox right now when the background read is not done yet: a change in the first moment after launch
    /// waits for it, as all of them did before.
    private func ensureLoaded() {
        guard !loaded else { return }
        finishLoading(Self.readInbox())
    }

    private var databasePath: String { NotificationRecord.databasePath(home: AppDatabase.home) }

    func start() {
        guard enabled else { return }
        // At launch the inbox is still being read in the background: collecting starts once it is in, instead of reading
        // it a second time here on the main thread.
        guard loaded else {
            startWhenLoaded = true
            return
        }
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
        catchUp.reset()
        // A Telegram session from an earlier login starts by itself; a new login starts from Settings › Connections.
        if sources.isOn(telegramBridge.app) { telegramBridge.resume() }
        timer = nil
        armTimer()
        planWatch = EnergyMonitor.shared.$plan.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.armTimer() }
        Task {
            await poll()
            await pollBridges()
        }
    }

    /// Follows the energy plan: `pollTick` skips ticks the plan does not want, and a tick that does nothing still wakes
    /// the Mac, every second, all night. Back at full speed it follows at once, since the plan is announced.
    private func armTimer() {
        let plan = EnergyMonitor.shared.plan
        let interval = plan.unseen ? Self.asleepInterval : Self.interval * plan.slowdown
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledCoalesced(withTimeInterval: interval) { [weak self] _ in
            Task { @MainActor in
                await self?.pollTick()
            }
        }
    }

    private var lastPollTime: Date = .distantPast

    /// Evaluates energy policy and display sleep state before polling databases.
    private func pollTick() async {
        let plan = EnergyMonitor.shared.plan
        if plan.unseen {
            guard Date().timeIntervalSince(lastPollTime) >= Self.asleepInterval - 0.25 else { return }
        } else {
            let interval = Self.interval * plan.slowdown
            guard Date().timeIntervalSince(lastPollTime) >= interval - 0.25 else { return }
        }
        lastPollTime = Date()
        await poll()
        await pollBridges()
    }

    func stop() {
        startWhenLoaded = false
        planWatch = nil
        timer?.invalidate()
        timer = nil
        generation += 1
        telegramBridge.stop()
        serviceBridge.stop()
        status = .off
    }

    /// Reads what was added to the database since the last look. Does nothing while the database did not change.
    func poll() async {
        // Not before the inbox is read (a connector's refresh at launch): `start` looks once it is in.
        guard enabled, !polling, loaded else { return }
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
            // Read without the write-ahead log (the database was locked): the newest notification may be missing.
            var complete = true
            // At most a few pages in one go; the rest of a backlog (a look back, a long sleep) follows on the next looks.
            for _ in 0..<5 {
                let read = try await AppDatabase.read(databasePath, NotificationRecord.query(
                    after: lastRecord, since: Date().addingTimeInterval(-Self.firstLook)), app: tr("chats.capture.source"))
                guard started == generation else { return }
                let rows = read.rows
                if !read.complete { complete = false }
                // The page goes into a copy, published once if anything in it changed: a change to the published inbox
                // (even an `add` that turned out a repeat) redrew the chats for every row, up to 200 a page.
                var next = inbox
                var pageChanged = false
                for row in rows {
                    guard let record = NotificationRecord.integer(row["id"]) else { continue }
                    lastRecord = max(lastRecord ?? record, record)
                    guard let notification = NotificationRecord.notification(row),
                          let notice = ChatCapture.notice(notification, webAppName: webAppName), !skips(notice) else { continue }
                    // A bridged app's notification says its bridge has something new: read it now, not at its next turn.
                    if isBridged(notice.app) {
                        if !replaying { nudge(notice.app, at: notice.date) }
                        // An app whose bridge reads no emoji (WhatsApp on this Mac) still says them in its notification:
                        // they go on the message. A bridge that reads them puts what the app says over it at its next read.
                        let placed = next.placed(notice)
                        if let reaction = ChatCapture.reaction(notice.text),
                           next.react(reaction, in: ChatInbox.key(app: notice.app, chat: placed.chat),
                                      by: ChatCapture.unmarked(placed.sender.isEmpty ? placed.chat : placed.sender),
                                      at: notice.date) {
                            pageChanged = true
                        }
                        continue
                    }
                    guard next.add(notice, id: "n\(notification.record)") else { continue }
                    pageChanged = true
                    // Looking back: what came in before `freshness` was likely seen on the Mac already.
                    let key = ChatInbox.key(app: notice.app, chat: notice.chat)
                    if replaying, notice.date < seen, let unread = next.threads[key]?.unread, unread > 0 {
                        next.threads[key]?.unread = unread - 1
                    }
                }
                if pageChanged {
                    inbox = next
                    changed = true
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
            // An incomplete look is not the database's state: the next tick looks again, even when it did not change.
            lastChange = complete ? change : nil
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
    /// A bridge counts only while it can read: one that worked and then lost its sign-in (or whose app the chat helper
    /// took over) keeps its last `isWorking` until its next read, which never comes while it is not ready.
    private func isBridged(_ app: String) -> Bool {
        bridges.contains { $0.app == app && $0.isReady && $0.isWorking }
            || (serviceBridge.isReady && serviceBridge.isWorking && serviceBridge.covered.contains(app))
    }

    /// Time between two reads at most of an app with a chat card up or a chat open: its card (or chat) shows a new
    /// message soon, also for an app that is otherwise read once a minute (Slack, Teams) and without its notifications.
    /// Not shorter: one Slack read asks for up to a dozen conversations, and Slack allows about fifty a minute.
    private static let watchGap: TimeInterval = 20

    /// The apps of the chats with a card up, and of the chat open in the Chats tab.
    private func watchedApps() -> Set<String> {
        var ids = watching()
        if let openChat { ids.insert(openChat) }
        guard !ids.isEmpty else { return [] }
        return Set(ids.compactMap { inbox.threads[$0]?.app })
    }

    /// Whether a bridge reads the app of a chat with a card up.
    private func watches(_ bridge: ChatBridge, _ apps: Set<String>) -> Bool {
        bridge === serviceBridge ? !apps.isDisjoint(with: serviceBridge.covered) : apps.contains(bridge.app)
    }

    /// Something was sent from Nook to a bridged app's chat: its bridge reads now, and again shortly after until the
    /// message is there, so it shows in the chat.
    func readSoon(_ app: String) {
        nudge(app, at: Date())
        // At once, not at the next tick of the timer. A notification needs no such call: the tick that read it reads the
        // bridges right after.
        Task { await pollBridges() }
    }

    /// A notification of a bridged app came in: its bridge reads now, and again after a growing gap until a read brings
    /// the message (`ChatCatchUp`), so the message shows in Nook moments after its app showed it.
    private func nudge(_ app: String, at date: Date) {
        // A bridge that keeps failing waits out its backoff: a nudge would otherwise ask a refusing service every second.
        // The chat helper reads the apps it covers: a notification of one of them nudges it, as any other bridge.
        liveAt[app] = date
        for bridge in bridges where watches(bridge, [app]) && bridgeFailures[bridge.bridgeID] == nil {
            bridgeDue[bridge.bridgeID] = nil
            catchUp.expect(bridge.bridgeID, at: date)
        }
    }

    /// A bridge whose app tells Nook what changed (WhatsApp's linked phone): it reads now, or once more right after the
    /// read that is going on, so nothing it said waits for its next turn.
    func readNow(_ bridge: ChatBridge) {
        guard !reading.contains(bridge.bridgeID) else {
            readAgain.insert(bridge.bridgeID)
            return
        }
        reading.insert(bridge.bridgeID)
        Task { await read(bridge) }
    }

    /// Bridges told to read again while they were reading.
    private var readAgain: Set<String> = []

    /// Reads a bridge now and returns once what it brought is in the inbox (after the read going on, if one is): a chat
    /// card asked for shows the chat as its app has it this moment.
    func readAndWait(_ bridge: ChatBridge) async {
        while reading.contains(bridge.bridgeID) { try? await Task.sleep(for: .milliseconds(50)) }
        reading.insert(bridge.bridgeID)
        await read(bridge)
    }

    /// Reads every bridge that is due, of the apps that are on. Runs next to the notifications, also while those cannot
    /// be read: Slack needs no disk access. Each bridge reads on its own: a slow one (a web service that takes seconds to
    /// answer) never holds up the others, so a message in a quick one shows the moment it is there.
    func pollBridges() async {
        var started: [Task<Void, Never>] = []
        let watched = watchedApps()
        for bridge in bridges {
            // Each write to these fires `objectWillChange`, which redraws every chat view: write only what changed, so a
            // quiet tick every second costs no redraw.
            guard (enabled && sources.isOn(bridge.app)) || bridge.alwaysOn, bridge.isReady else {
                // This runs every second for every bridge that is off: write only on a change, since each write to a
                // published property redraws every view that watches the inbox. What is said per app stays while
                // another bridge reads that app (WhatsApp through the phone, while WhatsApp on this Mac stands aside).
                if !bridges.contains(where: { $0 !== bridge && $0.app == bridge.app && $0.isReady }) {
                    if bridgeProblems[bridge.app] != nil { bridgeProblems[bridge.app] = nil }
                    if bridgeSignedOut.contains(bridge.app) { bridgeSignedOut.remove(bridge.app) }
                    if bridged.contains(bridge.app) { bridged.remove(bridge.app) }
                }
                // Signed in again later, it starts fresh instead of waiting out an old backoff.
                bridgeFailures[bridge.bridgeID] = nil
                if bridge === serviceBridge, !bridged.isDisjoint(with: serviceBridge.covered) { bridged.subtract(serviceBridge.covered) }
                continue
            }
            // One read per bridge at a time: the next waits until this one is done.
            let id = bridge.bridgeID
            guard !reading.contains(id) else { continue }
            if let due = bridgeDue[id], due > Date() { continue }
            let interval = watches(bridge, watched) ? min(bridge.interval, Self.watchGap) : bridge.interval
            bridgeDue[id] = Date().addingTimeInterval(catchUp.next(id).map { min(interval, $0) } ?? interval)
            reading.insert(id)
            started.append(Task { await self.read(bridge) })
        }
        for task in started { await task.value }
    }

    /// The bridges reading now, by `bridgeID`.
    private var reading: Set<String> = []

    /// One read of one bridge, merged into the inbox as soon as it is there.
    private func read(_ bridge: ChatBridge) async {
        defer {
            reading.remove(bridge.bridgeID)
            if readAgain.remove(bridge.bridgeID) != nil { readNow(bridge) }
        }
        let started = generation
        // Collecting switched on or off meanwhile makes a bridge's read stale; an app that reads on its own (WhatsApp's
        // linked phone) does not depend on it, and its read is kept.
        let current = { started == self.generation || bridge.alwaysOn }
        do {
            let chats = try await bridge.read()
            guard current() else { return }
            ensureLoaded()
            // Merged into a copy: a read that brings nothing new (most of them) then leaves the published inbox alone.
            let before = inbox
            var merged = inbox
            let mergedAny = merged.merge(chats)
            archiveBeyondWindow(chats, in: merged)
            let told = (bridge as? ChatNewsBridge)?.takeNews()
            if mergedAny {
                // A new message is live traffic: that app's backfill rests a while (`ChatBackfill.liveQuiet`).
                let readApps: Set<String> = bridge === serviceBridge ? serviceBridge.covered.union([bridge.app]) : [bridge.app]
                let now = Date()
                for app in readApps where !ChatInbox.added(before: before, after: merged, apps: [app]).isEmpty { liveAt[app] = now }
                if catchUp.isOwed(bridge.bridgeID) {
                    let apps: Set<String> = bridge === serviceBridge ? serviceBridge.covered.union([bridge.app]) : [bridge.app]
                    catchUp.read(bridge.bridgeID, brought: ChatInbox.added(before: before, after: merged, apps: apps))
                }
                inbox = merged
                save()
                if let told { announce(told) } else { announce(since: before) }
                // Read in the app since the last read: its count went to nothing without Nook marking it read.
                let read = merged.threads.values.filter { $0.unread == 0 && (before.threads[$0.id]?.unread ?? 0) > 0 }.map(\.id)
                if !read.isEmpty { onReadElsewhere(read) }
            }
            // News its app told without changing a chat (a chat that wrote again with what Nook already shows) is told too.
            if !mergedAny, let told, !told.isEmpty { announce(told) }
            if bridgeProblems[bridge.app] != nil { bridgeProblems[bridge.app] = nil }
            if bridgeSignedOut.contains(bridge.app) { bridgeSignedOut.remove(bridge.app) }
            bridgeFailures[bridge.bridgeID] = nil
            // The chat helper reads several apps: each one it brought in is bridged.
            let apps: Set<String> = bridge === serviceBridge ? serviceBridge.covered.union([bridge.app]) : [bridge.app]
            if !apps.isSubset(of: bridged) { bridged.formUnion(apps) }
        } catch {
            guard current() else { return }
            let problem = error.localizedDescription
            if bridgeProblems[bridge.app] != problem { bridgeProblems[bridge.app] = problem }
            let signedOut = ConnectorErrorKind.classify(error) == .auth
            if signedOut != bridgeSignedOut.contains(bridge.app) {
                if signedOut { bridgeSignedOut.insert(bridge.app) } else { bridgeSignedOut.remove(bridge.app) }
            }
            // Try again later, and later still each time it fails again: a minute, two, four… up to a quarter of an hour.
            // A database on this Mac that failed for a passing reason (a lock) starts at seconds, not a minute.
            let failures = (bridgeFailures[bridge.bridgeID] ?? 0) + 1
            // A failing bridge waits out its backoff, not the quick reads.
            catchUp.forget(bridge.bridgeID)
            bridgeFailures[bridge.bridgeID] = failures
            bridgeDue[bridge.bridgeID] = Date().addingTimeInterval(ChatBackoff.delay(
                interval: bridge.interval, failures: failures, local: bridge.readsLocally && !signedOut))
        }
    }

    /// A chat you opened: its app is read now (the chat helper reads that very chat again), so it shows what the app
    /// has at this moment, the same for every app Nook reads itself. A chat only notifications bring has nothing to ask.
    func refresh(_ id: String) {
        ensureLoaded()
        guard enabled, let thread = inbox.threads[id], thread.bridged == true else { return }
        liveAt[thread.app] = Date()
        if serviceBridge.refresh(app: thread.app, name: thread.name) {
            bridgeDue[serviceBridge.app] = nil
        } else if let bridge = bridge(for: thread.app) {
            bridgeDue[bridge.bridgeID] = nil
        } else {
            return
        }
        Task { await pollBridges() }
    }

    /// You are looking at this chat: the files it waits for go first, in an app that keeps a queue of its own.
    func hurryFiles(_ id: String) {
        guard enabled, let thread = inbox.threads[id], thread.bridged == true else { return }
        bridge(for: thread.app)?.hurryFiles(name: thread.name)
    }

    /// Tells about the chats someone wrote in since `before`, in the apps that are on.
    private func announce(since before: ChatInbox) {
        announce(ChatInbox.fresh(before: before, after: inbox, since: Date().addingTimeInterval(-Self.newsWindow)))
    }

    /// Tells about these chats, oldest news first: the ones that show and that the notice rules let reach you.
    private func announce(_ ids: [String]) {
        let rules = ChatNoticeRulesStore.shared.rules
        let fresh = ids
            .filter { id in
                guard let thread = inbox.threads[id], isShown(thread) else { return false }
                // A group that stays quiet still tells you about a message that names you.
                let newest = thread.messages.last { !$0.isMine }
                return !rules.isQuiet(chat: id, app: thread.app, kind: thread.noticeKind, mentionsMe: newest?.mentionsMe == true)
            }
        if !fresh.isEmpty { onFresh(fresh) }
    }

    /// Signs out of Snapchat for Web, after your own confirmation: what was read is forgotten and its row offers to sign
    /// in again.
    func signOutSnapchat() {
        SnapchatWebSession.shared.signOut()
        snapchatBridge.reset()
        bridgeChanged(snapchatBridge.app)
    }

    /// Links the Mail app: every account in it is read from now on and right away, Mail started out of sight when it is
    /// closed (the first read asks for permission under Automation), and Mail's chats are switched on.
    func linkMail() {
        Task {
            // A Mail that does not start still links: Nook reads it as soon as you open Mail yourself.
            try? await mailBridge.linkAndRead()
            loggedIn(mailBridge.app)
        }
    }

    /// Mail is linked but closed: starts it out of sight and reads it now, after your own click.
    func readMailNow() {
        Task {
            do {
                try await MailConnector.ensureRunning()
                bridgeChanged(mailBridge.app)
            } catch {
                bridgeProblems[mailBridge.app] = error.localizedDescription
            }
        }
    }

    /// Stops reading the Mail app, after your own confirmation: what was read is forgotten and its row offers to link
    /// it again. Mail itself and its accounts stay as they are.
    func unlinkMail() {
        mailBridge.setLinked(false)
        bridgeChanged(mailBridge.app)
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

    /// Adds a website or a known app's name, as typed in Settings › Connections.
    @discardableResult
    func addSource(_ typed: String, name: String = "") -> ChatSources.Added {
        var result = ChatSources.Added.invalid
        changeSources { result = $0.add(typed, name: name) }
        return result
    }

    /// Adds a Mac app chosen in Settings › Connections.
    @discardableResult
    func addSource(bundleID: String, name: String) -> ChatSources.Added {
        var result = ChatSources.Added.invalid
        changeSources { result = $0.add(bundleID: bundleID, name: name) }
        return result
    }

    /// Forgets an app you added, and the chats collected from it.
    func removeSource(_ id: String) {
        changeSources { $0.remove(id) }
        ensureLoaded()
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
    /// The chat's twins (`ChatInbox.twins`) are read with it: the badge counts them too, while the tab shows one.
    func markRead(_ id: String) {
        ensureLoaded()
        let ids = ([id] + inbox.twins(of: id)).filter { inbox.threads[$0]?.unread ?? 0 > 0 }
        guard !ids.isEmpty else { return }
        var next = inbox
        for id in ids { next.markRead(id) }
        inbox = next
        save()
    }

    /// Read in the app too: after Nook told the app, or opened the chat there. `through`: what the app was told
    /// (`ChatInbox.markReadInApp`), when telling it took a while.
    func markReadInApp(_ id: String, through: Date? = nil) {
        ensureLoaded()
        guard inbox.threads[id] != nil else { return }
        var next = inbox
        for id in [id] + next.twins(of: id) { next.markReadInApp(id, through: through) }
        inbox = next
        save()
    }

    /// Until when the chat counts as read in Nook now: what "Mark as read in <app>" tells the app, taken before it goes.
    func readMark(_ id: String) -> Date? {
        inbox.readMark(id)
    }

    /// When the chat was marked unread by hand, while it still is.
    func markedUnread(_ id: String) -> Date? {
        inbox.threads[id]?.markedUnread
    }

    /// Shows your emoji on a message (or takes it back) as you just sent it to its app.
    func toggleReaction(_ emoji: String, on message: String, in id: String) {
        ensureLoaded()
        inbox.toggleReaction(emoji, on: message, in: id)
        save()
    }

    func markUnread(_ id: String) {
        ensureLoaded()
        guard inbox.threads[id]?.unread == 0 else { return }
        inbox.markUnread(id)
        save()
    }

    /// Unread in the app too, after Nook told it (`ChatInbox.markUnreadInApp`); the chat and its twins.
    func markUnreadInApp(_ id: String) {
        ensureLoaded()
        guard inbox.threads[id] != nil else { return }
        var next = inbox
        for id in [id] + next.twins(of: id) { next.markUnreadInApp(id) }
        inbox = next
        save()
    }

    func markAllRead() {
        ensureLoaded()
        guard inbox.totalUnread > 0 else { return }
        inbox.markAllRead()
        save()
    }

    func remove(_ id: String) {
        ensureLoaded()
        inbox.remove(id)
        save()
    }

    /// The bridge that scrolls back in a chat: Nook's chat helper for the apps it links, else the app's own bridge
    /// (Messages and WhatsApp on this Mac, Slack, Telegram, Teams). Nil for a chat only notifications bring: what they
    /// brought is all there is, and the chat keeps every message of it.
    private func history(_ thread: InboxThread) -> ((Date, String?) async throws -> (chat: BridgedChat?, hasMore: Bool))? {
        // A chat its app knows by an id asks the bridge that gave it.
        if let chatID = thread.chatID {
            guard let bridge = bridges.compactMap({ $0 as? ChatKeyedHistoryBridge }).first(where: { $0.app == thread.app && $0.isReady }),
                  bridge.canLoadOlder(chatID: chatID) else { return nil }
            return { _, _ in try await bridge.older(chatID: chatID) }
        }
        if serviceBridge.chatID(app: thread.app, name: thread.name) != nil {
            return { [serviceBridge] before, _ in try await serviceBridge.older(app: thread.app, name: thread.name, before: before) }
        }
        guard let bridge = bridge(for: thread.app) as? ChatHistoryBridge, bridge.canLoadOlder(name: thread.name) else { return nil }
        return { before, oldest in try await bridge.older(name: thread.name, before: before, oldestID: oldest) }
    }

    /// What a read brought of messages older than what their chat shows: an edit or a deletion of an older message, or
    /// older history it brought along. The inbox lets go of those (the window holds the newest), so they go straight into
    /// the archive under the same rules (`ChatStore.saveMerged`, `withdraw`), and scrolling back shows them as they are
    /// now: "Edited", "Deleted", with the text an edit replaced kept. Nothing from before you removed a chat comes back.
    private func archiveBeyondWindow(_ chats: [BridgedChat], in inbox: ChatInbox) {
        guard let archive = ChatArchive.shared else { return }
        var work: [(key: String, thread: InboxThread, messages: [InboxMessage], deleted: [String])] = []
        for chat in chats where !chat.gone {
            let key = ChatInbox.key(of: chat)
            guard let thread = inbox.threads[key] else { continue }
            let shown = Set(thread.messages.map(\.id))
            let start = thread.messages.first?.date ?? .distantFuture
            let removed = inbox.removed?[key] ?? .distantPast
            let older = chat.messages.filter { !shown.contains($0.id) && $0.date < start && $0.date > removed }
            let deleted = chat.deleted.filter { !shown.contains($0) }
            if !older.isEmpty || !deleted.isEmpty { work.append((key, thread, older, deleted)) }
        }
        guard !work.isEmpty else { return }
        for item in work {
            if let first = item.messages.map(\.date).min(), oldestStored[item.key].map({ first < $0 }) ?? true {
                oldestStored[item.key] = first
            }
        }
        archive.write { store in
            store.transaction {
                work.allSatisfy { item in
                    guard let chat = store.chatID(item.key) ?? store.saveChat(item.thread) else { return false }
                    return item.messages.allSatisfy { store.saveMerged($0, chat: chat) } && store.withdraw(item.deleted, chat: chat)
                }
            }
        }
    }

    /// An edit or a deletion an app told of one message, for a message its bridge no longer holds (older than what it
    /// keeps in memory): the archive takes it, so scrolling back shows it edited or deleted. The same for every bridge
    /// that hears of changes one message at a time (WhatsApp through the linked phone, Telegram). A message the chat
    /// shows goes through the bridge's own read, as before. `text` nil: the app said it was edited, not to what.
    func archiveChange(chat key: String, message id: String, edited text: String? = nil, deleted: Bool = false) {
        guard let archive = ChatArchive.shared else { return }
        if inbox.threads[key]?.messages.contains(where: { $0.id == id }) == true { return }
        archive.write { store in
            guard let chat = store.chatID(key) else { return }
            store.transaction { deleted ? store.withdraw([id], chat: chat) : store.edit(id, chat: chat, to: text) }
        }
    }

    /// The texts a message had before it was edited or deleted, oldest first, as the archive kept them.
    func versions(chat key: String, message id: String) async -> [ChatVersion] {
        guard let archive = ChatArchive.shared else { return [] }
        return await archive.read { $0.versions(id, inChat: key) }
    }

    // MARK: Backfill

    /// Where a chat's history comes from, a page at a time, to lay beside the archive: the bridge that scrolls back in it
    /// by its name (Messages, WhatsApp on this Mac, Slack, Telegram, Teams, Snapchat), the chat helper (Instagram, Signal,
    /// Messenger, X, LinkedIn), or a bridge that knows the chat by an id (`ChatBackfillBridge`: WhatsApp through the linked
    /// phone, Mail). Its app's own data on this Mac is read quickly; a service is asked slowly.
    private struct HistorySource {
        var local: Bool
        var omitsDeleted: Bool
        var changes = true
        var textChangeIsEdit = false
        /// An empty page is the chat's start (`ChatBackfillBridge.backfillEmptyIsStart`).
        var emptyIsFinal = false
        /// The page before a message (its date, and its id when the app pages by id): the messages, the ones the app
        /// says were deleted, and whether it has more before them (nil when it does not say).
        var fetch: (Date, String?) async throws -> Fetched
    }

    /// One page from a history source: its messages, those the app says were deleted (by id, or as copies under ids
    /// of their own: `ChatReconcile.Page.gone`), and whether it has more before them (nil when it does not say).
    private struct Fetched {
        var messages: [InboxMessage]
        var deleted: [String] = []
        var gone: [InboxMessage] = []
        var more: Bool?
    }

    private func historySource(_ thread: InboxThread) -> HistorySource? {
        if let chatID = thread.chatID {
            guard let bridge = bridges.compactMap({ $0 as? ChatBackfillBridge }).first(where: { $0.app == thread.app && $0.isReady }),
                  bridge.canBackfill(chatID: chatID) else { return nil }
            let final = bridge.backfillEmptyIsStart
            return HistorySource(local: bridge.readsLocally, omitsDeleted: bridge.historyOmitsDeleted,
                                 changes: bridge.historyChanges, emptyIsFinal: final) { before, _ in
                let page = try await bridge.backfillPage(chatID: chatID, before: before, limit: ChatBackfill.step)
                return Fetched(messages: page.messages, gone: page.gone,
                               more: final && page.messages.isEmpty && page.gone.isEmpty ? false : nil)
            }
        }
        if serviceBridge.chatID(app: thread.app, name: thread.name) != nil {
            return HistorySource(local: false, omitsDeleted: serviceBridge.historyOmitsDeleted) { [serviceBridge] before, _ in
                let (chat, more) = try await serviceBridge.older(app: thread.app, name: thread.name, before: before)
                return Fetched(messages: chat?.messages ?? [], deleted: chat?.deleted ?? [], more: more)
            }
        }
        guard let bridge = bridge(for: thread.app) as? ChatHistoryBridge, bridge.isReady, bridge.canLoadOlder(name: thread.name) else {
            return nil
        }
        return HistorySource(local: bridge.readsLocally, omitsDeleted: bridge.historyOmitsDeleted,
                             changes: bridge.historyChanges, textChangeIsEdit: bridge.historyTextChangeIsEdit) { before, oldest in
            let (chat, more) = try await bridge.older(name: thread.name, before: before, oldestID: oldest)
            return Fetched(messages: chat?.messages ?? [], deleted: chat?.deleted ?? [], more: more)
        }
    }

    /// Starts walking each chat's whole history in the background (`ChatBackfill`).
    private func startBackfill() {
        guard ChatArchive.shared != nil, backfillTimer == nil else { return }
        backfillTimer = Timer.scheduledCoalesced(withTimeInterval: ChatBackfill.tick) { [weak self] _ in
            Task { @MainActor in await self?.backfillTick() }
        }
    }

    /// One page of one chat's history from its app, laid beside the archive (`ChatStore.reconcile`): what Nook missed
    /// is added, so a hole closes; an edit or a deletion of an old message reaches it; past the oldest message stored the
    /// archive grows back to the chat's start. Each chat is walked from the oldest message it shows down to its start,
    /// and again after `ChatBackfill.rewalk` (first after each launch, which closes what came in while Nook was not
    /// running). Each app has its own pace (`ChatBackfill.pause`). The chat's window in memory stays as it is.
    func backfillTick(now: Date = Date()) async {
        guard enabled, loaded, !backfilling, let archive = ChatArchive.shared else { return }
        if freeBytes.map({ now.timeIntervalSince($0.at) >= ChatBackfill.diskCheck }) ?? true {
            freeBytes = (DiskSpace.available(), now)
        }
        guard ChatBackfill.allowed(EnergyMonitor.shared.plan, freeBytes: freeBytes?.bytes) else { return }
        // Chats with something written (a walk starts below it), newest first; among them the one asked longest ago, so
        // one long chat does not keep the others waiting.
        let candidates = inbox.sorted.filter { thread in
            oldestStored[thread.id] != nil && isShown(thread) && !thread.messages.isEmpty
                && (walks[thread.id] != nil || now.timeIntervalSince(walkedAt[thread.id] ?? .distantPast) >= ChatBackfill.rewalk)
                && (backfillDue[thread.app] ?? .distantPast) <= now
                && !liveBusy(thread.app, now: now)
        }
        let ordered = candidates.enumerated().sorted { a, b in
            let (x, y) = (backfillAsked[a.element.id] ?? .distantPast, backfillAsked[b.element.id] ?? .distantPast)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        guard let (thread, source) = ordered.lazy.compactMap({ thread in self.historySource(thread).map { (thread, $0) } }).first,
              let first = thread.messages.first
        else { return }
        let key = thread.id
        backfillAsked[key] = now
        backfilling = true
        defer { backfilling = false }
        var walk: ChatBackfill.Walk
        if let going = walks[key] {
            walk = going
        } else {
            walk = ChatBackfill.Walk(cursor: first.date, cursorID: first.id)
            walk.reachedStartBefore = await archive.read { $0.isComplete(key) }
        }
        walks[key] = walk
        backfillDue[thread.app] = now.addingTimeInterval(ChatBackfill.pause(local: source.local))
        let fetched: Fetched
        do {
            fetched = try await ChatBackfill.$filling.withValue(true) { try await source.fetch(walk.cursor, walk.cursorID) }
        } catch {
            // The app could not answer now (signed out, offline, too many questions): it waits longer.
            backfillDue[thread.app] = Date().addingTimeInterval(ChatBackfill.pause(local: source.local) * 10)
            return
        }
        // The chat was removed or cleared while its app answered: nothing of it comes back, nor anything from before you
        // cleared it.
        guard inbox.threads[key] != nil else {
            walks[key] = nil
            return
        }
        let page = ChatBackfill.messages(fetched.messages, below: walk, removed: inbox.removed?[key])
        let fresh: Int?
        if page.isEmpty && fetched.deleted.isEmpty && fetched.gone.isEmpty {
            fresh = 0
        } else {
            let laid = ChatReconcile.Page(messages: page, deleted: fetched.deleted, high: walk.cursor, omitsDeleted: source.omitsDeleted,
                                           textChangeIsEdit: source.textChangeIsEdit, gone: fetched.gone)
            fresh = await archive.written { $0.reconcile(laid, key: key) }
        }
        guard let fresh else {
            walks[key] = nil
            return
        }
        if let oldest = page.min(by: { $0.date < $1.date }) {
            if oldestStored[key].map({ oldest.date < $0 }) ?? true { oldestStored[key] = oldest.date }
            if oldest.date < walk.cursor || fresh > 0 {
                walks[key] = ChatBackfill.Walk(cursor: oldest.date, cursorID: oldest.id, reachedStartBefore: walk.reachedStartBefore)
                if fetched.more == false {
                    endWalk(key, now: now, atStart: true)
                } else if !source.changes, walk.reachedStartBefore, fresh == 0 {
                    // Nothing new where the archive already held it all, in an app whose old messages never change.
                    endWalk(key, now: now, atStart: false)
                }
                return
            }
        }
        // Nothing before it: the chat's start, or a bridge busy with the same chat this moment (you scrolling back
        // there). Only nothing a few times in a row, each after the app's pause, counts as the start, unless the app's
        // empty answer is final.
        if page.isEmpty, fetched.more == false, source.emptyIsFinal {
            endWalk(key, now: now, atStart: true)
            return
        }
        var next = walk
        next.empty += 1
        walks[key] = next
        if next.empty >= ChatBackfill.emptyToFinish { endWalk(key, now: now, atStart: true) }
    }

    /// Whether an app's live reads go first now: it had live traffic moments ago, a quick read is still owed to one of
    /// its bridges, or one of them waits out a refusal (`ChatBackoff`), which a page of old history would only prolong.
    private func liveBusy(_ app: String, now: Date) -> Bool {
        if now.timeIntervalSince(liveAt[app] ?? .distantPast) < ChatBackfill.liveQuiet { return true }
        return bridges.contains { bridge in
            watches(bridge, [app]) && (bridgeFailures[bridge.bridgeID] != nil || catchUp.isOwed(bridge.bridgeID))
        }
    }

    private func endWalk(_ key: String, now: Date, atStart: Bool) {
        walks[key] = nil
        walkedAt[key] = now
        if atStart { ChatArchive.shared?.write { $0.markComplete(key) } }
    }

    /// The stretch just shown from the archive, laid beside the chat's app as you scroll back: what Nook missed there
    /// comes in, and an edit or deletion the app knows shows, without waiting for the walk to get there. Quietly: what
    /// you see changes only where the app has something else.
    private func checkStored(_ id: String, before high: Date, from cursorID: String?) {
        guard let archive = ChatArchive.shared, !checking.contains(id), let thread = inbox.threads[id],
              let source = historySource(thread) else { return }
        checking.insert(id)
        Task { @MainActor in
            defer { checking.remove(id) }
            guard let fetched = try? await source.fetch(high, cursorID), inbox.threads[id] != nil else { return }
            let page = ChatBackfill.messages(fetched.messages, below: ChatBackfill.Walk(cursor: high, cursorID: cursorID),
                                         removed: inbox.removed?[id])
            guard let low = (page.map(\.date) + fetched.gone.map(\.date)).min() else { return }
            let laid = ChatReconcile.Page(messages: page, deleted: fetched.deleted, high: high, omitsDeleted: source.omitsDeleted,
                                           textChangeIsEdit: source.textChangeIsEdit, gone: fetched.gone)
            guard await archive.written({ $0.reconcile(laid, key: id) }) != nil else { return }
            let after = low.addingTimeInterval(-ChatBackfill.instant)
            let now = await archive.read { $0.between(id, after: after, before: high) }
            showStretch(id, now, after: after, before: high)
        }
    }

    /// The messages a chat shows between two times, as the archive now has them.
    private func showStretch(_ id: String, _ stored: [InboxMessage], after: Date, before: Date) {
        func replaced(_ thread: InboxThread) -> InboxThread {
            var thread = thread
            let outside = thread.messages.filter { !($0.date > after && $0.date < before) }
            thread.messages = Self.inserting(stored, into: outside)
            thread.capacity = max(thread.capacity ?? 0, thread.messages.count)
            return thread
        }
        guard let current = inbox.threads[id] else { return }
        let next = replaced(current)
        guard next.messages != current.messages else { return }
        inbox.threads[id] = next
        // Already written: the next save need not write them again.
        if let saved = lastSaved?.threads[id] { lastSaved?.threads[id] = replaced(saved) }
    }

    /// A chat whose app keeps older messages than Nook shows, until its start was reached.
    func canLoadOlder(_ id: String) -> Bool {
        guard let thread = inbox.threads[id] else { return false }
        if storesOlder(thread) { return true }
        guard !noOlder.contains(id), thread.hasOlder != false else { return false }
        return history(thread) != nil
    }

    /// The archive holds messages of this chat older than the ones it shows.
    private func storesOlder(_ thread: InboxThread) -> Bool {
        guard let oldest = oldestStored[thread.id] else { return false }
        return oldest < thread.messages.first?.date ?? .distantFuture
    }

    /// The batch before the oldest message a chat shows, from the archive: one index lookup, no app asked. False when
    /// the archive has none.
    private func loadStoredOlder(_ id: String) async -> Bool {
        guard let archive = ChatArchive.shared, let thread = inbox.threads[id], storesOlder(thread) else { return false }
        let window = Set(thread.messages.map(\.id))
        let before = thread.messages.first?.date ?? Date()
        let older = await archive.read { $0.older(id, before: before, excluding: window, limit: ChatHistory.step) }
        guard var current = inbox.threads[id] else { return false }
        let known = Set(current.messages.map(\.id))
        let fresh = older.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else {
            // Nothing older after all (the dates said otherwise): the app is asked from now on.
            oldestStored[id] = current.messages.first?.date
            return false
        }
        current.messages = Self.inserting(fresh, into: current.messages)
        current.capacity = current.messages.count
        inbox.threads[id] = current
        // Laid beside the app right after, so a hole there or a change the archive missed shows too.
        checkStored(id, before: before, from: thread.messages.first?.id)
        // Already written: the next save need not write them again.
        if var saved = lastSaved?.threads[id] {
            let savedIDs = Set(saved.messages.map(\.id))
            saved.messages = Self.inserting(fresh.filter { !savedIDs.contains($0.id) }, into: saved.messages)
            saved.capacity = current.capacity
            lastSaved?.threads[id] = saved
        }
        return true
    }

    /// `messages` put in their places by date among `list` (oldest first), as the inbox places a message.
    static func inserting(_ messages: [InboxMessage], into list: [InboxMessage]) -> [InboxMessage] {
        var result = list
        for message in messages.sorted(by: { $0.date < $1.date }) {
            let index = result.lastIndex { $0.date <= message.date }.map { $0 + 1 } ?? 0
            result.insert(message, at: index)
        }
        return result
    }

    /// Scrolls back in a chat: the batch before the oldest message it shows, kept from now on. No cap: each scroll back
    /// goes further, as far as the app keeps the chat. False when no older one came in.
    func loadOlder(_ id: String) async -> Bool {
        ensureLoaded()
        if await loadStoredOlder(id) { return true }
        guard let thread = inbox.threads[id], let history = history(thread) else { return false }
        let before = thread.messages.count
        let oldest = thread.messages.first
        do {
            let (chat, hasMore) = try await history(oldest?.date ?? Date(), oldest?.id)
            if !hasMore { noOlder.insert(id) }
            guard let chat else { return false }
            var merged = inbox
            merged.grow(id, by: chat.messages.count)
            merged.merge(chat)
            archiveBeyondWindow([chat], in: merged)
            let after = merged.threads[id]?.messages.count ?? before
            guard after > before else { return false }
            inbox = merged
            save()
            return true
        } catch {
            return false
        }
    }

    /// An app whose messages Nook may not keep was turned off (WhatsApp through the linked phone): its chats let go of
    /// them, in memory as they never were on disk. What Nook knows of each chat itself stays.
    func forgetMessages(of ids: Set<String>) {
        ensureLoaded()
        var next = inbox
        next.forgetMessages(of: ids)
        guard next != inbox else { return }
        inbox = next
        ChatArchive.shared?.write { store in store.transaction { ids.allSatisfy { store.deleteChat($0, keepChat: true) } } }
        for id in ids { oldestStored[id] = nil }
        save()
    }

    /// Chats of an account you removed: gone from Nook, without the mark a chat you removed leaves (no newer message
    /// brings them back, since nothing reads that account any more).
    func drop(_ ids: Set<String>) {
        ensureLoaded()
        let gone = ids.filter { inbox.threads[$0] != nil }
        guard !gone.isEmpty else { return }
        for id in gone { inbox.threads[id] = nil }
        ChatArchive.shared?.write { store in store.transaction { gone.allSatisfy { store.deleteChat($0) } } }
        for id in gone { oldestStored[id] = nil }
        save()
    }

    /// Chats brought over from another app (`BeeperImporter`), merged like a bridge's; how many changed.
    func importChats(_ chats: [BridgedChat]) -> Int {
        ensureLoaded()
        var changed = 0
        for chat in chats where inbox.merge(chat) { changed += 1 }
        archiveBeyondWindow(chats, in: inbox)
        if changed > 0 { save() }
        return changed
    }

    /// Forgets every collected chat; the next look starts after the newest notification.
    func clear() {
        ensureLoaded()
        let last = inbox.lastRecord
        let lookedBack = inbox.lookedBack
        inbox = ChatInbox()
        inbox.lastRecord = last
        inbox.lookedBack = lookedBack
        ChatArchive.shared?.write { $0.deleteAll() }
        lastSaved = nil
        oldestStored = [:]
        save()
        // A linked phone's chats are WhatsApp's own, not collected: they come back at once.
        whatsAppGatewayBridge.handAllOver()
    }

    /// The database's last change: the file, or its write-ahead log where macOS writes first.
    private func modified() -> Date? {
        [databasePath, databasePath + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
            .max()
    }

    /// A write of `chat-inbox.json` is waiting (see `save`).
    private var savePending = false
    private static let saving = DispatchQueue(label: "nook.chat-inbox.save", qos: .utility)

    /// Writes `chat-inbox.json` a moment after a change, off the main thread, once for all changes in that moment. With
    /// many chats the file is large, and encoding all of it on the main thread after each bridge read kept the CPU busy.
    private func save() {
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.flushSave() }
        }
    }

    /// Writes what is waiting now; `wait` holds on until it is on disk (Nook quits). With the archive only what changed
    /// since the last save is written: a read that brought one message writes one row, not the whole inbox.
    private func flushSave(wait: Bool = false) {
        guard savePending, loaded else { return }
        savePending = false
        let inbox = inbox
        if let archive = ChatArchive.shared {
            let previous = lastSaved
            lastSaved = inbox
            for thread in inbox.threads.values {
                guard let first = thread.messages.first?.date else { continue }
                if oldestStored[thread.id].map({ first < $0 }) ?? true { oldestStored[thread.id] = first }
            }
            let write: @Sendable (ChatStore) -> Void = { store in
                // A write that failed leaves the archive as it was: the next one writes everything again.
                if !store.apply(from: previous, to: inbox) { store.apply(from: nil, to: inbox) }
            }
            if wait { archive.writeNow(write) } else { archive.write(write) }
            return
        }
        let file = Self.file
        let write: @Sendable () -> Void = {
            // A chat whose app keeps its messages (WhatsApp through the linked phone) is written without them.
            guard let data = try? JSONEncoder().encode(inbox.forDisk) else { return }
            try? SafeStorage.write(data, to: file)
        }
        if wait { Self.saving.sync(execute: write) } else { Self.saving.async(execute: write) }
    }
}
