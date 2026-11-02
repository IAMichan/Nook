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
        bridges.compactMap { $0 as? any ChatSearchBridge }.filter { bridge in
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
    private var bridgeDue: [String: Date] = [:]
    /// Quick reads still owed to a bridge after one of its app's notifications: the app's own server can list the
    /// message a few seconds after it notified, so one read right away may still miss it.
    private var bridgeNudges: [String: Int] = [:]
    /// Reads in a row that failed, per app: each one waits longer before the next try (`ChatBackoff`).
    private var bridgeFailures: [String: Int] = [:]

    /// How often the database is looked at. Only a database that changed is read, so looking is cheap; looking often
    /// matters because Slack and Teams take a notification back as soon as you read the message elsewhere.
    private static let interval: TimeInterval = 1
    /// A first start shows what came in this long ago: macOS keeps the notifications it showed for a while, so the
    /// chats of the last weeks are there at once instead of only the ones that write after switching on.
    private static let firstLook: TimeInterval = 14 * 86_400
    /// What came in before this long ago, on a first start, counts as read: it was likely seen on the Mac already.
    private static let freshness: TimeInterval = 3600

    private nonisolated static var file: URL { NookPaths.supportDirectory.appendingPathComponent("chat-inbox.json") }
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

    private nonisolated static func readInbox() -> ChatInbox {
        var inbox = SafeStorage.load(ChatInbox.self, from: file).value ?? ChatInbox()
        inbox.trim()
        return inbox
    }

    private func finishLoading(_ read: ChatInbox) {
        guard !loaded else { return }
        loaded = true
        inbox = read
        if startWhenLoaded {
            startWhenLoaded = false
            start()
        }
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
        bridgeNudges = [:]
        // A Telegram session from an earlier login starts by itself; a new login starts from Settings › Connections.
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
        startWhenLoaded = false
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
                for row in rows {
                    guard let record = NotificationRecord.integer(row["id"]) else { continue }
                    lastRecord = max(lastRecord ?? record, record)
                    guard let notification = NotificationRecord.notification(row),
                          let notice = ChatCapture.notice(notification, webAppName: webAppName), !skips(notice) else { continue }
                    // A bridged app's notification says its bridge has something new: read it now, not at its next turn.
                    if isBridged(notice.app) {
                        if !replaying { nudge(notice.app) }
                        // An app whose bridge reads no emoji (WhatsApp on this Mac) still says them in its notification:
                        // they go on the message. A bridge that reads them puts what the app says over it at its next read.
                        let placed = inbox.placed(notice)
                        if let reaction = ChatCapture.reaction(notice.text),
                           inbox.react(reaction, in: ChatInbox.key(app: notice.app, chat: placed.chat),
                                       by: ChatCapture.unmarked(placed.sender.isEmpty ? placed.chat : placed.sender),
                                       at: notice.date) {
                            changed = true
                        }
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

    /// Time between the quick reads after a bridged app's notification.
    private static let nudgeGap: TimeInterval = 5
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

    /// Something was sent from Nook to a bridged app's chat: its bridge reads now, and twice more shortly after, so the
    /// message shows in the chat.
    func readSoon(_ app: String) { nudge(app) }

    /// A notification of a bridged app came in: its bridge reads now, and twice more shortly after.
    private func nudge(_ app: String) {
        // A bridge that keeps failing waits out its backoff: a nudge would otherwise ask a refusing service every second.
        // The chat helper reads the apps it covers: a notification of one of them nudges it, as any other bridge.
        for bridge in bridges where watches(bridge, [app]) && bridgeFailures[bridge.bridgeID] == nil {
            bridgeDue[bridge.bridgeID] = nil
            bridgeNudges[bridge.bridgeID] = 3
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
            let nudges = bridgeNudges[id] ?? 0
            bridgeNudges[id] = nudges > 1 ? nudges - 1 : nil
            let interval = watches(bridge, watched) ? min(bridge.interval, Self.watchGap) : bridge.interval
            bridgeDue[id] = Date().addingTimeInterval(nudges > 1 ? min(interval, Self.nudgeGap) : interval)
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
            let told = (bridge as? ChatNewsBridge)?.takeNews()
            if mergedAny {
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
        if serviceBridge.refresh(app: thread.app, name: thread.name) {
            bridgeDue[serviceBridge.app] = nil
        } else if let bridge = bridge(for: thread.app) {
            bridgeDue[bridge.bridgeID] = nil
        } else {
            return
        }
        Task { await pollBridges() }
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
        inbox.threads[id]?.readInNook
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

    /// A chat whose app keeps older messages than Nook shows, until its start was reached.
    func canLoadOlder(_ id: String) -> Bool {
        guard let thread = inbox.threads[id], !noOlder.contains(id), thread.hasOlder != false else { return false }
        return history(thread) != nil
    }

    /// Scrolls back in a chat: the batch before the oldest message it shows, kept from now on. No cap: each scroll back
    /// goes further, as far as the app keeps the chat. False when no older one came in.
    func loadOlder(_ id: String) async -> Bool {
        ensureLoaded()
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
        save()
    }

    /// Chats of an account you removed: gone from Nook, without the mark a chat you removed leaves (no newer message
    /// brings them back, since nothing reads that account any more).
    func drop(_ ids: Set<String>) {
        ensureLoaded()
        let gone = ids.filter { inbox.threads[$0] != nil }
        guard !gone.isEmpty else { return }
        for id in gone { inbox.threads[id] = nil }
        save()
    }

    /// Chats brought over from another app (`BeeperImporter`), merged like a bridge's; how many changed.
    func importChats(_ chats: [BridgedChat]) -> Int {
        ensureLoaded()
        var changed = 0
        for chat in chats where inbox.merge(chat) { changed += 1 }
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

    /// Writes what is waiting now; `wait` holds on until it is on disk (Nook quits).
    private func flushSave(wait: Bool = false) {
        guard savePending, loaded else { return }
        savePending = false
        let inbox = inbox
        let file = Self.file
        let write = {
            // A chat whose app keeps its messages (WhatsApp through the linked phone) is written without them.
            guard let data = try? JSONEncoder().encode(inbox.forDisk) else { return }
            try? SafeStorage.write(data, to: file)
        }
        if wait { Self.saving.sync(execute: write) } else { Self.saving.async(execute: write) }
    }
}
