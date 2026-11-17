import ActivityKit
import Foundation

/// The phone's side of Live Activities (docs/COMPANION.md › Live Activities): it hands the Mac the push-to-start token
/// and each activity's update token, so the Mac can start, update and end them while the app is closed, and keeps them
/// current itself while the app is open. A switch in the app turns them off.
///
/// ActivityKit answers most questions (`activities`, `activityState`, `content`, whether the system allows them) with a
/// synchronous call to iOS' Live Activity service. Those never run on the main thread here: the Mac sends a list update
/// every few seconds while agents work, and a slow service then froze the app until iOS killed it.
@MainActor
final class LiveActivities: ObservableObject {
    static let shared = LiveActivities()

    private static let enabledKey = "liveActivities.enabled"
    private static let startTokenKey = "liveActivities.startToken"

    /// On by default; off ends every activity and tells the Mac to send none.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            Task { await enabledChanged() }
        }
    }

    /// Whether the Mac can push Live Activities (the answer to the last registration), nil while unknown.
    @Published private(set) var macReady: Bool? {
        didSet { if macReady != oldValue { lastPlan = nil } }
    }

    /// iOS lets the user turn Live Activities off for the app in Settings. Kept here, filled off the main thread and
    /// followed through `activityEnablementUpdates`: views read it on every redraw.
    @Published private(set) var allowedBySystem = true

    /// Whether the app is in front: only then does it keep the activities current itself; in the background the Mac's
    /// pushes do (`CompanionClient.appBecameActive`, `appWentToBackground`).
    var inFront = false {
        didSet { if inFront != oldValue { lastPlan = nil } }
    }

    private var watching = false
    private var observed: Set<String> = []
    /// The newest tokens, kept so they can be sent again when the Mac was not reachable (or after the switch was off).
    private var startToken: String?
    private var activityTokens: [String: String] = [:]
    private var needsSync = true
    /// Sessions whose activity ended here a moment ago: not started again right away.
    private var ended: [String: Date] = [:]
    /// One reconcile at a time: a list that comes in meanwhile waits here (only the newest), and runs right after.
    private var reconciling = false
    private var pendingSessions: [SessionDigest]?
    /// What the last reconcile acted on. The same plan again (the Mac sends the list for every change, most of which no
    /// activity shows) asks ActivityKit nothing; an activity that came or went, or a changed setting, clears it.
    private var lastPlan: Plan?

    /// Everything a reconcile depends on besides ActivityKit's own state.
    private struct Plan: Equatable, Sendable {
        var snapshots: [LiveActivitySnapshot]
        var macStarts: Bool
        var cooling: Set<String>
    }

    private typealias NookActivity = Activity<NookActivityAttributes>

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        startToken = UserDefaults.standard.string(forKey: Self.startTokenKey)
    }

    /// Starts listening for tokens and activities. Called once the app runs.
    func start() {
        guard !watching else { return }
        watching = true
        Task { [weak self] in
            let (info, allowed) = await Self.offMain {
                let info = ActivityAuthorizationInfo()
                return (info, info.areActivitiesEnabled)
            }
            self?.allowedBySystem = allowed
            for await allowed in info.activityEnablementUpdates {
                self?.allowedBySystem = allowed
                self?.lastPlan = nil
            }
        }
        if #available(iOS 17.2, *) {
            Task { [weak self] in
                for await data in NookActivity.pushToStartTokenUpdates {
                    let token = APNsJWT.tokenHex(data)
                    UserDefaults.standard.set(token, forKey: Self.startTokenKey)
                    self?.startToken = token
                    self?.needsSync = true
                    await self?.sync()
                }
            }
        }
        Task { [weak self] in
            for await activity in NookActivity.activityUpdates { self?.observe(activity) }
        }
        Task { [weak self] in
            for activity in await Self.offMain({ NookActivity.activities }) { self?.observe(activity) }
        }
    }

    private func observe(_ activity: NookActivity) {
        guard observed.insert(activity.id).inserted else { return }
        lastPlan = nil
        let session = activity.attributes.session
        let id = activity.id
        Task { [weak self] in
            // A session has one activity: one the Mac started while the app also started one is a twin, and goes.
            let twin = await Self.offMain {
                NookActivity.activities.contains { $0.id != id && $0.attributes.session == session && $0.activityState == .active }
            }
            if twin { await activity.end(nil, dismissalPolicy: .immediate) } else { self?.follow(activity, session: session) }
        }
    }

    private func follow(_ activity: NookActivity, session: String) {
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                self?.activityTokens[session] = APNsJWT.tokenHex(data)
                self?.needsSync = true
                await self?.sync()
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                await self?.activityEnded(session)
                break
            }
        }
    }

    private func activityEnded(_ session: String) async {
        ended[session] = Date()
        lastPlan = nil
        // A twin may still run for this session; its token stays.
        let twin = await Self.offMain {
            NookActivity.activities.contains { $0.attributes.session == session && $0.activityState == .active }
        }
        guard !twin else { return }
        activityTokens[session] = nil
        await register(LiveActivityRegistration(kind: .ended, session: session, production: CompanionClient.apnsProduction))
    }

    /// Sends the tokens the Mac does not have yet.
    func sync() async {
        guard needsSync, enabled, CompanionClient.shared.can(CompanionFeature.liveActivity) else { return }
        var ok = true
        if let startToken {
            ok = await register(LiveActivityRegistration(kind: .pushToStart, token: startToken, production: CompanionClient.apnsProduction)) && ok
        }
        for (session, token) in activityTokens {
            ok = await register(LiveActivityRegistration(kind: .activity, token: token, session: session,
                                                         production: CompanionClient.apnsProduction)) && ok
        }
        if ok { needsSync = false }
    }

    @discardableResult
    private func register(_ registration: LiveActivityRegistration) async -> Bool {
        guard let message = await CompanionClient.shared.registerLive(registration) else { return false }
        macReady = message == "push"
        return true
    }

    private func enabledChanged() async {
        lastPlan = nil
        if enabled {
            needsSync = true
            await sync()
            await reconcile(CompanionClient.shared.sessions)
        } else {
            await endAll()
            await register(LiveActivityRegistration(kind: .off, production: CompanionClient.apnsProduction))
        }
    }

    /// Unpaired, or switched off: every activity goes at once.
    func endAll() async {
        await Self.endAll()
        activityTokens = [:]
        needsSync = true
        lastPlan = nil
    }

    private nonisolated static func endAll() async {
        for activity in NookActivity.activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Runs `work` (a synchronous ActivityKit call) away from the main thread: a nonisolated async function runs on the
    /// global executor (SE-0338), not on the caller's actor.
    private nonisolated static func offMain<T>(_ work: () -> T) async -> T {
        work()
    }

    /// While the app is open it keeps the activities current itself, with the same rules as the Mac
    /// (`LiveActivityPlanner`): a working or waiting session has one, done or failed ends it and stays 15 minutes.
    /// Lists that arrive while one is applied are folded into one run with the newest.
    func reconcile(_ sessions: [SessionDigest]) async {
        pendingSessions = sessions
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        while let next = pendingSessions {
            pendingSessions = nil
            await reconcileNow(next)
        }
    }

    private func reconcileNow(_ sessions: [SessionDigest]) async {
        await sync()
        guard enabled, allowedBySystem, inFront else { return }
        let now = Date()
        ended = ended.filter { now.timeIntervalSince($0.value) < LiveActivityPlanner.startCooldown }
        // The Mac starts activities by push when it can; starting one here too would make a twin.
        let plan = Plan(snapshots: sessions.map { LiveActivitySnapshot(digest: $0) }, macStarts: macReady == true && startToken != nil,
                        cooling: Set(ended.keys))
        guard plan != lastPlan else { return }
        lastPlan = plan
        let started = await Self.apply(plan, now: now)
        for activity in started { observe(activity) }
    }

    /// Brings ActivityKit in line with `plan`, off the main thread; returns the activities it started.
    private nonisolated static func apply(_ plan: Plan, now: Date) async -> [NookActivity] {
        var running: [String: NookActivity] = [:]
        for activity in NookActivity.activities where activity.activityState == .active { running[activity.attributes.session] = activity }
        let listed = Set(plan.snapshots.map(\.session))
        var started: [NookActivity] = []

        for snapshot in plan.snapshots {
            if let activity = running[snapshot.session] {
                let old = activity.content.state
                let since = old.phase == snapshot.phase ? Date(timeIntervalSince1970: old.since) : now
                let content = LiveActivityPlanner.content(snapshot, since: since)
                if snapshot.phase.isFinished {
                    await activity.end(ActivityContent(state: content, staleDate: nil),
                                       dismissalPolicy: .after(now.addingTimeInterval(LiveActivityPlanner.finishedVisible)))
                } else if content != old {
                    await activity.update(ActivityContent(state: content, staleDate: now.addingTimeInterval(LiveActivityPlanner.staleAfter)))
                }
            } else if !snapshot.phase.isFinished, !plan.macStarts, !plan.cooling.contains(snapshot.session),
                      running.count < LiveActivityPlanner.maxActivities {
                let content = LiveActivityPlanner.content(snapshot, since: now)
                if let activity = try? NookActivity.request(
                    attributes: snapshot.attributes,
                    content: ActivityContent(state: content, staleDate: now.addingTimeInterval(LiveActivityPlanner.staleAfter)),
                    pushType: .token) {
                    running[snapshot.session] = activity
                    started.append(activity)
                }
            }
        }
        // Gone from the Mac's list (archived or removed).
        for (session, activity) in running where !listed.contains(session) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return started
    }
}
