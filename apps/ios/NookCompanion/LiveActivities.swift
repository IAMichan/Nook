import ActivityKit
import Foundation

/// The phone's side of Live Activities (docs/COMPANION.md › Live Activities): it hands the Mac the push-to-start token
/// and each activity's update token, so the Mac can start, update and end them while the app is closed, and keeps them
/// current itself while the app is open. A switch in the app turns them off.
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
    @Published private(set) var macReady: Bool?

    private var watching = false
    private var observed: Set<String> = []
    /// The newest tokens, kept so they can be sent again when the Mac was not reachable (or after the switch was off).
    private var startToken: String?
    private var activityTokens: [String: String] = [:]
    private var needsSync = true
    /// Sessions whose activity ended here a moment ago: not started again right away.
    private var ended: [String: Date] = [:]

    private typealias NookActivity = Activity<NookActivityAttributes>

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        startToken = UserDefaults.standard.string(forKey: Self.startTokenKey)
    }

    /// iOS lets the user turn Live Activities off for the app in Settings.
    var allowedBySystem: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Starts listening for tokens and activities. Called once the app runs.
    func start() {
        guard !watching else { return }
        watching = true
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
        for activity in NookActivity.activities { observe(activity) }
    }

    private func observe(_ activity: NookActivity) {
        guard observed.insert(activity.id).inserted else { return }
        let session = activity.attributes.session
        // A session has one activity: one the Mac started while the app also started one is a twin, and goes.
        if NookActivity.activities.contains(where: { $0.id != activity.id && $0.attributes.session == session && $0.activityState == .active }) {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
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
        // A twin may still run for this session; its token stays.
        guard !NookActivity.activities.contains(where: { $0.attributes.session == session && $0.activityState == .active }) else { return }
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
        for activity in NookActivity.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        activityTokens = [:]
        needsSync = true
    }

    /// While the app is open it keeps the activities current itself, with the same rules as the Mac
    /// (`LiveActivityPlanner`): a working or waiting session has one, done or failed ends it and stays 15 minutes.
    func reconcile(_ sessions: [SessionDigest]) async {
        await sync()
        guard enabled, allowedBySystem else { return }
        let now = Date()
        ended = ended.filter { now.timeIntervalSince($0.value) < LiveActivityPlanner.startCooldown }
        var running: [String: NookActivity] = [:]
        for activity in NookActivity.activities where activity.activityState == .active { running[activity.attributes.session] = activity }
        // The Mac starts activities by push when it can; starting one here too would make a twin.
        let macStarts = macReady == true && startToken != nil
        let listed = Set(sessions.map(\.id))

        for session in sessions {
            let snapshot = LiveActivitySnapshot(digest: session)
            if let activity = running[session.id] {
                let old = activity.content.state
                let since = old.phase == snapshot.phase ? Date(timeIntervalSince1970: old.since) : now
                let content = LiveActivityPlanner.content(snapshot, since: since)
                if snapshot.phase.isFinished {
                    await activity.end(ActivityContent(state: content, staleDate: nil),
                                       dismissalPolicy: .after(now.addingTimeInterval(LiveActivityPlanner.finishedVisible)))
                } else if content != old {
                    await activity.update(ActivityContent(state: content, staleDate: now.addingTimeInterval(LiveActivityPlanner.staleAfter)))
                }
            } else if !snapshot.phase.isFinished, !macStarts, ended[session.id] == nil,
                      running.count < LiveActivityPlanner.maxActivities {
                let content = LiveActivityPlanner.content(snapshot, since: now)
                if let activity = try? NookActivity.request(
                    attributes: snapshot.attributes,
                    content: ActivityContent(state: content, staleDate: now.addingTimeInterval(LiveActivityPlanner.staleAfter)),
                    pushType: .token) {
                    running[session.id] = activity
                    observe(activity)
                }
            }
        }
        // Gone from the Mac's list (archived or removed).
        for (session, activity) in running where !listed.contains(session) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
