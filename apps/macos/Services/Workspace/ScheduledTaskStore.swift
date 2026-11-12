import Foundation
import Combine
import Security

/// What a scheduled task may do beyond the pure `ScheduledTask` row: the permission policy the user chose for it in the
/// editor. A task that never stored one runs with "ask" (every edit and command prompts), see `effectivePermission`.
struct ScheduledTaskOptions: Codable, Equatable, Sendable {
    var permission: PermissionPolicy = .ask
    /// A webhook task's filters, duplicate key and coalesce window (`WebhookRules`).
    var webhook = WebhookRules()

    init(permission: PermissionPolicy = .ask, webhook: WebhookRules = WebhookRules()) {
        self.permission = permission
        self.webhook = webhook
    }

    private enum CodingKeys: String, CodingKey { case permission, webhook }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permission = (try? c.decode(PermissionPolicy.self, forKey: .permission)) ?? .ask
        webhook = (try? c.decode(WebhookRules.self, forKey: .webhook)) ?? WebhookRules()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(permission, forKey: .permission)
        if !webhook.isEmpty { try c.encode(webhook, forKey: .webhook) }
    }
}

/// Scheduled tasks as the app runs them (F7): the list on disk, a 30 second timer that starts what is due, and the
/// webhook deliveries that wait for their turn. The decisions (when, missed, overlap, duplicates) are in the pure
/// cores in `ScheduledTasks.swift` and `WebhookSecurity.swift`; this owns the timers, the storage and the sessions.
///
/// Safety: everything is off until `WorkspaceSettings.scheduledTasksEnabled` is on. A task starts an ordinary session
/// with the permission policy stored on the task, "ask" when there is none; a task a webhook starts is always "ask",
/// because its payload comes from outside. Webhook signing secrets live in the keychain (`SecretStore`), never in the file.
@MainActor
final class ScheduledTaskStore: ObservableObject {
    static let shared = ScheduledTaskStore()

    @Published private(set) var tasks: [ScheduledTask] = []
    @Published private(set) var options: [UUID: ScheduledTaskOptions] = [:]
    /// Per webhook task, what happened to its latest deliveries (newest first, at most `WebhookDeliveryRecord.limit`).
    @Published private(set) var deliveries: [UUID: [WebhookDeliveryRecord]] = [:]
    /// Per webhook task, the duplicate keys of the last week.
    private var dedupe: [UUID: WebhookDedupe] = [:]
    private var coalescer = WebhookCoalescer<Delivery>()

    /// The seconds between two checks for due tasks.
    static let tickSeconds: TimeInterval = 30

    private let fileURL: URL
    private weak var app: AppModel?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private var ledger = FireLedger()
    private var gate = RunGate()
    private var webhookQueue = WebhookQueue()
    /// Webhook deliveries that wait for their task to be free, oldest first.
    private var pending: [UUID: [Delivery]] = [:]
    /// Task → the session it started, for tasks that are running now.
    private var running: [UUID: UUID] = [:]
    private var runningTrigger: [UUID: ScheduleTrigger] = [:]

    private struct Delivery: Sendable {
        var id: String
        var request: WebhookRequestData
        var receivedAt: Date
        /// Deliveries a coalesce window folded into this one.
        var combined = 1
    }

    enum WebhookAdmission: Equatable, Sendable {
        case accepted, queueFull, unknownTask
        /// Verified, but a filter or the duplicate key said not to run: answered as received, logged, nothing runs.
        case filtered, duplicate
    }

    enum RunNowResult: Equatable, Sendable {
        case started, busy, notAvailable
    }

    // MARK: Storage

    private struct StoreFile: Codable {
        var version = 1
        var tasks: LossyArray<ScheduledTask>
        var options: [String: ScheduledTaskOptions]
        var deliveries: [String: [WebhookDeliveryRecord]] = [:]
        var dedupe: [String: WebhookDedupe] = [:]

        private enum CodingKeys: String, CodingKey { case version, tasks, options, deliveries, dedupe }

        init(tasks: [ScheduledTask], options: [String: ScheduledTaskOptions], deliveries: [String: [WebhookDeliveryRecord]],
             dedupe: [String: WebhookDedupe]) {
            self.tasks = LossyArray(tasks)
            self.options = options
            self.deliveries = deliveries
            self.dedupe = dedupe
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 1
            tasks = (try? c.decode(LossyArray<ScheduledTask>.self, forKey: .tasks)) ?? LossyArray([])
            options = (try? c.decode([String: ScheduledTaskOptions].self, forKey: .options)) ?? [:]
            deliveries = (try? c.decode([String: [WebhookDeliveryRecord]].self, forKey: .deliveries)) ?? [:]
            dedupe = (try? c.decode([String: WebhookDedupe].self, forKey: .dedupe)) ?? [:]
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(fileURL: URL = NookPaths.supportDirectory.appendingPathComponent("scheduled-tasks.json")) {
        self.fileURL = fileURL
        load()
    }

    private func load(now: Date = Date()) {
        // An unreadable file is kept aside by SafeStorage; the next save never wipes the only copy.
        let file = SafeStorage.load(StoreFile.self, from: fileURL, decoder: Self.decoder, skipped: { $0.tasks.skipped }).value
        let loaded = file?.tasks.elements ?? []
        // A run a restart cut off becomes failed and is rescheduled; it must not block the task or count as success.
        var recovered = ScheduledTask.recoverInterrupted(tasks: loaded, now: now)
        for index in recovered.indices where recovered[index].enabled && recovered[index].nextRun == nil && !recovered[index].rule.isWebhook {
            recovered[index].nextRun = recovered[index].plannedRun(now: now)
        }
        for index in recovered.indices where !recovered[index].enabled { recovered[index].nextRun = nil }
        tasks = recovered
        var map: [UUID: ScheduledTaskOptions] = [:]
        for (key, value) in file?.options ?? [:] { if let id = UUID(uuidString: key) { map[id] = value } }
        options = map
        func byTask<T>(_ stored: [String: T]?) -> [UUID: T] {
            var out: [UUID: T] = [:]
            for (key, value) in stored ?? [:] { if let id = UUID(uuidString: key) { out[id] = value } }
            return out
        }
        deliveries = byTask(file?.deliveries)
        dedupe = byTask(file?.dedupe)
        if recovered != loaded { save() }
    }

    private func save() {
        func byKey<T>(_ map: [UUID: T]) -> [String: T] { Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) }) }
        let file = StoreFile(tasks: tasks, options: byKey(options), deliveries: byKey(deliveries), dedupe: byKey(dedupe))
        guard let data = try? Self.encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: Lifecycle

    /// Called once when the app starts: hooks the store up to the sessions and to the settings gate.
    func attach(app: AppModel) {
        guard !started else { return }
        started = true
        self.app = app
        // A session that ends (also while the notch is closed) ends the task run that started it.
        app.workspace.$runs
            // `runs` publishes for every streamed token; a task run only ends when a session's status changes.
            .removeDuplicates { $0.map(\.id) == $1.map(\.id) && $0.map(\.status) == $1.map(\.status) }
            .sink { [weak self] runs in
                // `$runs` publishes before the change lands; look again on the next turn of the run loop.
                DispatchQueue.main.async { self?.checkRuns(runs) }
            }
            .store(in: &cancellables)
        let settings = WorkspaceSettings.shared
        settings.$scheduledTasksEnabled
            .combineLatest(settings.$scheduledWebhookPort)
            .removeDuplicates(by: ==)
            .sink { [weak self] enabled, port in
                DispatchQueue.main.async { self?.apply(enabled: enabled, port: port) }
            }
            .store(in: &cancellables)
        WebhookListener.shared.attach(self)
        $tasks.map { $0.contains { $0.enabled && $0.rule.isWebhook } }
            .combineLatest(settings.$scheduledTasksEnabled, settings.$scheduledWebhooksPublic)
            .map { $0 && $1 && $2 }
            .removeDuplicates()
            .combineLatest(CompanionRelayClient.shared.$mode.map { _ in () }.prepend(()),
                           CompanionRelayClient.shared.$address.removeDuplicates())
            .sink { wanted, _, _ in
                // Also when the relay itself changes; published before it lands, so one turn later.
                DispatchQueue.main.async { WebhookRelayClient.shared.set(wanted: wanted) }
            }
            .store(in: &cancellables)
    }

    private func apply(enabled: Bool, port: Int) {
        if enabled {
            if timer == nil {
                let timer = Timer(timeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                tick()
            }
            if (1024...65535).contains(port) {
                WebhookListener.shared.start(port: UInt16(port), store: self)
            } else {
                WebhookListener.shared.stop()
            }
        } else {
            timer?.invalidate()
            timer = nil
            WebhookListener.shared.stop()
        }
    }

    var isEnabled: Bool { WorkspaceSettings.shared.scheduledTasksEnabled }

    func isRunning(_ id: UUID) -> Bool { gate.isRunning(id) }

    // MARK: Editing

    func task(_ id: UUID) -> ScheduledTask? { tasks.first { $0.id == id } }

    /// Adds a task, or replaces the one with the same id. A changed schedule counts from now, so editing never fires a
    /// task at once because its old schedule was overdue; a once-task that ran stays done until its moment changes.
    /// `webhook` nil keeps the task's webhook rules as they are.
    func save(_ task: ScheduledTask, permission: PermissionPolicy, webhook: WebhookRules? = nil, now: Date = Date()) {
        var row = task
        let old = self.task(task.id)
        if let old {
            row.lastRun = old.lastRun; row.lastStatus = old.lastStatus; row.lastError = old.lastError
            if old.rule != row.rule && old.rule.isWebhook {
                SecretStore.remove(Self.secretAccount(task.id))
                deliveries[task.id] = nil
                dedupe[task.id] = nil
            }
        }
        row.nextRun = row.plannedRun(now: now, keepsHistory: old?.rule == row.rule)
        if gate.isRunning(row.id) { row.lastStatus = .running; row.nextRun = nil }
        if let index = tasks.firstIndex(where: { $0.id == row.id }) { tasks[index] = row } else { tasks.append(row) }
        options[row.id] = ScheduledTaskOptions(permission: permission, webhook: webhook ?? options[row.id]?.webhook ?? WebhookRules())
        if row.rule.isWebhook { _ = webhookSecret(for: row.id, create: true) }
        save()
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        options[id] = nil
        pending[id] = nil
        deliveries[id] = nil
        dedupe[id] = nil
        coalescer.forget(id)
        webhookQueue.forget(id)
        SecretStore.remove(Self.secretAccount(id))
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].enabled = enabled
        if enabled {
            if !gate.isRunning(id) { tasks[index].nextRun = tasks[index].plannedRun(now: now) }
        } else {
            tasks[index].nextRun = nil
            // Deliveries that waited for a paused task are dropped, which the queue's counter has to know.
            for _ in pending[id] ?? [] { webhookQueue.release(id) }
            pending[id] = nil
            if coalescer.windows[id] != nil { webhookQueue.release(id); coalescer.forget(id) }
        }
        save()
    }

    func webhookRules(for id: UUID) -> WebhookRules { options[id]?.webhook ?? WebhookRules() }

    func permission(for id: UUID) -> PermissionPolicy { options[id]?.permission ?? .ask }

    // MARK: Webhook secrets (keychain only)

    static func secretAccount(_ id: UUID) -> String { "scheduled-task-webhook." + id.uuidString.lowercased() }

    func webhookSecret(for id: UUID, create: Bool = false) -> String? {
        if let secret = SecretStore.read(Self.secretAccount(id)) { return secret }
        guard create else { return nil }
        return rotateWebhookSecret(id)
    }

    /// A new random secret; the old one stops working at once and deliveries waiting for it are dropped.
    @discardableResult
    func rotateWebhookSecret(_ id: UUID) -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = WebhookHex.encode(Data(bytes))
        guard SecretStore.write(secret, account: Self.secretAccount(id)) == errSecSuccess else { return nil }
        for _ in pending[id] ?? [] { webhookQueue.release(id) }
        pending[id] = nil
        if coalescer.windows[id] != nil { webhookQueue.release(id); coalescer.forget(id) }
        return secret
    }

    func webhookURL(for id: UUID) -> String? {
        let port = WorkspaceSettings.shared.scheduledWebhookPort
        guard (1024...65535).contains(port) else { return nil }
        return "http://127.0.0.1:\(port)/hooks/\(id.uuidString)"
    }

    // MARK: Timer

    /// Starts what is due. A fixed-time run that is more than ten minutes late (the Mac slept) is skipped and the next one
    /// is planned; an interval that is overdue runs once. Public so a test or a wake-from-sleep hook can call it.
    func tick(now: Date = Date()) {
        guard isEnabled else { return }
        for task in tasks where task.enabled && !task.rule.isWebhook && !gate.isRunning(task.id) {
            guard let due = task.nextRun else {
                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[index].nextRun = ScheduleTiming.nextRun(rule: task.rule, lastFinished: task.lastRun, now: now)
                    save()
                }
                continue
            }
            guard due <= now else { continue }
            if ScheduleTiming.shouldSkip(rule: task.rule, scheduledFor: due, now: now) {
                recordSkip(task.id, reason: "sched.skip.missed", now: now)
                continue
            }
            fire(task.id, scheduledFor: due, trigger: .schedule, prompt: task.prompt, now: now)
        }
    }

    /// "Run now" from the list: the task's own prompt, once, if it is free.
    @discardableResult
    func runNow(_ id: UUID, now: Date = Date()) -> RunNowResult {
        guard isEnabled, let task = task(id) else { return .notAvailable }
        if gate.isRunning(id) { return .busy }
        return fire(id, scheduledFor: now, trigger: .manual, prompt: task.prompt, now: now) ? .started : .busy
    }

    // MARK: Webhooks

    /// A verified delivery (the listener checked signature, replay and rate). The task's rules go first: a failing filter
    /// or a key seen before ends it here (logged, nothing runs); inside an open coalesce window it replaces the delivery
    /// that waits there. Otherwise it waits in the task's queue of 20 until the task is free. The payload is data; it
    /// reaches the agent only inside `WebhookPrompt`.
    func acceptWebhook(taskID: UUID, deliveryID: String, payload: Data, headers: [String: String] = [:],
                       now: Date = Date()) -> WebhookAdmission {
        guard isEnabled, let task = task(taskID), task.enabled, task.rule.isWebhook else { return .unknownTask }
        let rules = webhookRules(for: taskID)
        let request = WebhookRequestData(body: payload, headers: headers)
        if let failed = rules.failingFilter(request) {
            log(taskID, deliveryID, .filtered, failed.summary, now: now)
            return .filtered
        }
        if let key = WebhookTemplate.renderKey(rules.duplicateKey, request: request) {
            var seen = dedupe[taskID] ?? WebhookDedupe()
            let first = seen.claim(key, now: now)
            dedupe[taskID] = seen
            guard first else {
                log(taskID, deliveryID, .duplicate, key, now: now)
                return .duplicate
            }
        }
        let delivery = Delivery(id: deliveryID, request: request, receivedAt: now)
        if let window = rules.coalesceWindow {
            // A window that closed but was not flushed yet goes first, so it is not overwritten.
            flushCoalesced(taskID, now: now)
            if coalescer.windows[taskID].map({ $0.closesAt > now }) == true {
                if case .merged(let count) = coalescer.add(delivery, task: taskID, seconds: window, now: now) {
                    log(taskID, deliveryID, .coalesced, String(count), now: now)
                }
                return .accepted
            }
            guard webhookQueue.admit(taskID) == .accepted else {
                log(taskID, deliveryID, .queueFull, nil, now: now)
                return .queueFull
            }
            if case .opened(let closes) = coalescer.add(delivery, task: taskID, seconds: window, now: now) {
                log(taskID, deliveryID, .accepted, String(Int(window)), now: now)
                scheduleFlush(taskID, at: closes)
            }
            return .accepted
        }
        guard webhookQueue.admit(taskID) == .accepted else {
            log(taskID, deliveryID, .queueFull, nil, now: now)
            return .queueFull
        }
        log(taskID, deliveryID, .accepted, nil, now: now)
        pending[taskID, default: []].append(delivery)
        drainWebhooks(taskID, now: now)
        return .accepted
    }

    /// When the window closes, its latest delivery joins the queue (its place was taken when the window opened).
    private func scheduleFlush(_ taskID: UUID, at closes: Date) {
        Task { [weak self] in
            let wait = max(0, closes.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 50_000_000)
            self?.flushCoalesced(taskID)
        }
    }

    /// Public for tests: moves a closed window's delivery into the queue.
    func flushCoalesced(_ taskID: UUID, now: Date = Date()) {
        guard let window = coalescer.flush(taskID, now: now) else { return }
        guard task(taskID)?.enabled == true else { webhookQueue.release(taskID); return }
        var delivery = window.latest
        delivery.combined = window.count
        pending[taskID, default: []].append(delivery)
        drainWebhooks(taskID, now: now)
    }

    private func log(_ taskID: UUID, _ deliveryID: String, _ outcome: WebhookDeliveryRecord.Outcome, _ detail: String?, now: Date) {
        let record = WebhookDeliveryRecord(deliveryID: deliveryID, receivedAt: now, outcome: outcome, detail: detail)
        deliveries[taskID] = WebhookDeliveryRecord.appending(record, to: deliveries[taskID] ?? [])
        save()
    }

    private func drainWebhooks(_ taskID: UUID, now: Date = Date()) {
        guard !gate.isRunning(taskID), var queue = pending[taskID], !queue.isEmpty, let task = task(taskID) else { return }
        guard task.enabled else {
            for _ in queue { webhookQueue.release(taskID) }
            pending[taskID] = nil
            return
        }
        let next = queue.removeFirst()
        pending[taskID] = queue.isEmpty ? nil : queue
        let prompt = WebhookPrompt.build(taskPrompt: task.prompt, request: next.request, deliveryID: next.id,
                                         receivedAt: next.receivedAt, combined: next.combined)
        if !fire(taskID, scheduledFor: next.receivedAt, trigger: .webhook, prompt: prompt, now: now) {
            // Could not start (duplicate key): the delivery is gone, free its place.
            webhookQueue.release(taskID)
            drainWebhooks(taskID, now: now)
        }
    }

    // MARK: Firing

    /// The one way a run starts. False when nothing started: the same firing was seen already, or the task is busy.
    @discardableResult
    private func fire(_ id: UUID, scheduledFor: Date, trigger: ScheduleTrigger, prompt: String, now: Date) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let key = ScheduledTask.fireKey(taskID: id, scheduledFor: scheduledFor, trigger: trigger)
        guard ledger.claim(key) else { return false }
        guard gate.begin(id) else {
            // Overlap: a tick that finds the task busy skips this round instead of piling a second run on it.
            if trigger == .schedule { recordSkip(id, reason: "sched.skip.overlap", now: now) }
            return false
        }
        tasks[index].lastRun = now
        tasks[index].lastStatus = .running
        tasks[index].lastError = nil
        tasks[index].nextRun = nil
        runningTrigger[id] = trigger
        save()
        let task = tasks[index]
        Task { await launch(task, prompt: prompt, trigger: trigger) }
        return true
    }

    /// The permission a run gets: what the user stored on the task, "ask" when nothing is stored, and always "ask" for a
    /// webhook run, whose payload is not from the user. A policy the agent does not offer falls back to "ask".
    nonisolated static func effectivePermission(stored: PermissionPolicy?, provider: RunProvider, trigger: ScheduleTrigger) -> PermissionPolicy {
        // Nothing unattended runs with full rights, whatever an old row says.
        // "Auto" steps down to "allow edits": its reviewer would approve commands nobody watches.
        let capped: PermissionPolicy? = stored.map { $0.isUnattendedSafe ? $0 : ($0 == .bypass ? .ask : .acceptEdits) }
        let wanted: PermissionPolicy = trigger == .webhook ? .ask : (capped ?? .ask)
        let offered = provider.capabilities.policies
        if offered.contains(wanted) { return wanted }
        return offered.contains(.ask) ? .ask : (offered.first ?? .ask)
    }

    private func launch(_ task: ScheduledTask, prompt: String, trigger: ScheduleTrigger) async {
        guard let app else { return finish(task.id, status: .failed, error: "sched.error.notReady") }
        switch task.target {
        case .newSession(let path, let providerName, let profileID):
            guard let provider = RunProvider(rawValue: providerName), !path.isEmpty else {
                return finish(task.id, status: .failed, error: "sched.error.badTarget")
            }
            var config = NewRunConfig()
            config.title = task.title
            config.task = prompt
            config.provider = provider
            config.profileID = profileID ?? (app.connectedProfiles(for: provider).first ?? app.profiles.preferredProfile(provider.kind)).id
            config.mode = .agent
            config.permission = Self.effectivePermission(stored: options[task.id]?.permission, provider: provider, trigger: trigger)
            config.isolation = .folder
            config.projectPath = path
            config.worktreeRoot = WorkspaceSettings.shared.worktreeRoot
            do {
                let sessionID = try await app.workspace.start(config)
                running[task.id] = sessionID
                checkRuns(app.workspace.runs)
            } catch {
                finish(task.id, status: .failed, error: error.localizedDescription)
            }
        case .existingSession(let sessionID, let fresh):
            guard let run = app.workspace.run(sessionID) else { return finish(task.id, status: .failed, error: "sched.error.noSession") }
            // Never interrupts a session that is working: that is the overlap rule for sessions.
            guard run.canContinue else { return finish(task.id, status: .skipped, error: "sched.skip.overlap") }
            // What comes from outside must not work with rights you gave that session for yourself.
            guard trigger != .webhook || run.permission == .ask else {
                return finish(task.id, status: .failed, error: "sched.error.webhookRights")
            }
            // A fresh conversation each run: the agent starts over, the timeline keeps every earlier run. When the last turn
            // is still finishing (its snapshot), the prompt waits in line marked fresh and starts the new conversation then.
            let cleared = fresh && app.workspace.startFreshConversation(sessionID, reason: tr("automation.sched.freshEvent", task.title))
            app.workspace.submit(sessionID, text: prompt, fresh: fresh && !cleared)
            finish(task.id, status: .succeeded, error: nil)
        }
    }

    /// A started session that is no longer active ends the run of its task.
    private func checkRuns(_ runs: [WorkspaceRun]) {
        for (taskID, sessionID) in running {
            guard let run = runs.first(where: { $0.id == sessionID }) else {
                finish(taskID, status: .failed, error: "sched.error.noSession")
                continue
            }
            guard !run.status.isActive else { continue }
            switch run.status {
            case .completed: finish(taskID, status: .succeeded, error: nil)
            case .failed: finish(taskID, status: .failed, error: run.statusDetail)
            default: finish(taskID, status: .failed, error: run.statusDetail ?? run.status.rawValue)
            }
        }
    }

    private func finish(_ id: UUID, status: ScheduledRunStatus, error: String?, now: Date = Date()) {
        running[id] = nil
        let trigger = runningTrigger.removeValue(forKey: id)
        gate.finish(id)
        if trigger == .webhook { webhookQueue.release(id) }
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            let started = tasks[index].lastRun
            NookTelemetry.shared.scheduledRunFinished(status: status, trigger: trigger, started: started, now: now)
            var row = tasks[index].finishing(status: status, error: error, at: now)
            if row.rule.isWebhook { row.nextRun = nil }
            // `finishing` stamps the end time; the list shows when the run started.
            row.lastRun = started ?? now
            tasks[index] = row
            save()
        }
        drainWebhooks(id)
    }

    private func recordSkip(_ id: UUID, reason: String, now: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let before = tasks[index]
        var row = before.finishing(status: .skipped, error: reason, at: now)
        row.lastRun = before.lastRun
        // A skip must not erase the outcome of the run that is still going.
        if gate.isRunning(id) { row.lastStatus = .running; row.lastError = nil; row.nextRun = nil }
        tasks[index] = row
        save()
    }
}
