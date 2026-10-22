import Foundation

/// One pull request opened in Nook (see PullRequestDetailView): what it shows, and how it stays current.
///
/// Opening is quick because the page never waits for everything: the summary (the pull request, its repository and the
/// checks of its head) shows as soon as it is in, the timeline, commits and files follow. Every pull request read while
/// Nook runs is kept, so opening it again shows it at once and refreshes underneath; one under the pointer in the list
/// is read ahead (`prefetch`). While open, the summary is read again every 15 seconds while checks run or GitHub is still
/// working out mergeability, else every 30; the activity only when the summary says something changed.
@MainActor
final class PullRequestDetailModel: ObservableObject {
    let accountID: String
    let item: PullRequestItem

    @Published private(set) var detail: PullRequestDetail?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// When the shown summary was read.
    @Published private(set) var fetchedAt: Date?
    /// Set while a merge runs, so a refresh does not read the pull request halfway through it.
    var paused = false

    /// Merged from this page: GitHub's answer already said so, so a read that started before the merge (or reads a
    /// replica that has not caught up) cannot turn it back to open.
    private var mergedHere = false
    /// A refresh was asked for while one ran: it runs again right after.
    private var again = false
    private var againActivity = false
    private var activityKey: String?
    private var activityAt = Date.distantPast

    private var key: String { Self.key(accountID, item.id) }

    init(accountID: String, item: PullRequestItem) {
        self.accountID = accountID
        self.item = item
        if let cached = Self.cache[Self.key(accountID, item.id)] {
            detail = cached.detail
            fetchedAt = cached.at
            activityKey = Self.activityKey(cached.detail)
            activityAt = cached.detail.activityLoaded ? cached.at : .distantPast
        }
    }

    // MARK: Staying current

    /// Reads the pull request while the page is open; ends when the task that runs it is cancelled.
    func run() async {
        if let pending = Self.prefetching[key] {
            await pending.value
            adoptCache()
        }
        let recent = fetchedAt.map { Date().timeIntervalSince($0) < 10 } ?? false
        if !recent || detail?.activityLoaded != true { await refresh() }
        // GitHub works out mergeability after the first ask: look again once it has.
        if let detail, detail.isOpen, detail.mergeable == nil {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { await refresh() }
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if !Task.isCancelled, !paused { await refresh() }
        }
    }

    /// How long until the next look: sooner while something is about to change.
    private var interval: TimeInterval {
        guard let detail else { return 15 }
        guard detail.isOpen else { return 120 }
        let busy = detail.mergeable == nil || detail.checks.contains { $0.outcome == .pending }
        return busy ? 15 : 30
    }

    /// Reads the summary, and the activity too when it is missing, `activity` asks for it, two minutes passed, or the
    /// summary shows a change (a push, a comment, a review, a label). Returns at once while a read is running, after
    /// asking it to go again.
    func refresh(activity: Bool = false) async {
        guard !loading else {
            again = true
            againActivity = againActivity || activity
            return
        }
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else {
            if detail == nil { error = tr("agents.pr.noToken") }
            return
        }
        loading = true
        defer { loading = false }
        var forceActivity = activity
        repeat {
            again = false
            forceActivity = forceActivity || againActivity
            againActivity = false
            let repo = item.repo, number = item.number, counts = detail
            // Started next to the summary when it is needed anyway, so a first open costs one round less.
            var activityTask: Task<PullRequestActivity, Never>? = nil
            if forceActivity || detail?.activityLoaded != true || Date().timeIntervalSince(activityAt) > 120 {
                activityTask = Self.readActivity(repo: repo, number: number, token: token, counts: counts)
            }
            do {
                // Not tied to the page: leaving the pull request halfway must not end the read as a failed one.
                let fresh = try await Task { try await GitHubPullRequestDetail.summary(repo: repo, number: number, token: token) }.value
                show(fresh.keepingActivity(of: detail))
                error = nil
                let changed = Self.activityKey(fresh) != activityKey
                if activityTask == nil, changed {
                    activityTask = Self.readActivity(repo: repo, number: number, token: token, counts: fresh)
                }
                if let activityTask {
                    let activity = await activityTask.value
                    if var shown = detail {
                        shown.apply(activity)
                        show(shown)
                    }
                    activityKey = Self.activityKey(fresh)
                    activityAt = Date()
                }
            } catch {
                activityTask?.cancel()
                // A failed refresh keeps what was shown, quietly: the next one is never far away.
                if detail == nil { self.error = error.localizedDescription }
            }
            forceActivity = false
        } while again && !Task.isCancelled
    }

    /// The merge went through: shows it here, in the list and on the agent rows at once.
    func markMerged() {
        mergedHere = true
        guard var shown = detail else { return }
        shown.state = .merged
        show(shown)
        PullRequestStore.shared.markMerged(shown.id)
        PullRequestSync.shared.markMerged(repository: shown.repo, number: shown.number)
    }

    private func show(_ fresh: PullRequestDetail) {
        var fresh = fresh
        if mergedHere, fresh.isOpen { fresh.state = .merged }
        if fresh != detail { detail = fresh }
        fetchedAt = Date()
        Self.remember(fresh, key: key)
        PullRequestStore.shared.update(with: fresh)
    }

    private func adoptCache() {
        guard let cached = Self.cache[key], cached.at > (fetchedAt ?? .distantPast) else { return }
        detail = cached.detail
        fetchedAt = cached.at
        activityKey = Self.activityKey(cached.detail)
        if cached.detail.activityLoaded { activityAt = cached.at }
    }

    // MARK: Kept between visits

    private struct Cached {
        let detail: PullRequestDetail
        let at: Date
    }

    private static var cache: [String: Cached] = [:]
    private static var prefetching: [String: Task<Void, Never>] = [:]
    /// Enough for a morning of reviews; the oldest go first.
    private static let cacheLimit = 40

    private static func key(_ account: String, _ id: String) -> String { account + " " + id }

    /// What changes when the timeline, the commits or the files may have: the last update, the head, the state.
    private static func activityKey(_ detail: PullRequestDetail) -> String {
        "\(detail.updated?.timeIntervalSince1970 ?? 0)|\(detail.headSHA)|\(detail.state.rawValue)"
    }

    private static func readActivity(repo: String, number: Int, token: String, counts: PullRequestDetail?) -> Task<PullRequestActivity, Never> {
        Task.detached(priority: .userInitiated) {
            await GitHubPullRequestDetail.loadActivity(repo: repo, number: number, token: token, counts: counts)
        }
    }

    private static func remember(_ detail: PullRequestDetail, key: String) {
        cache[key] = Cached(detail: detail, at: Date())
        guard cache.count > cacheLimit else { return }
        let oldest = cache.sorted { $0.value.at < $1.value.at }.prefix(cache.count - cacheLimit).map(\.key)
        for key in oldest { cache[key] = nil }
    }

    /// Reads a pull request ahead, while the pointer rests on its row, so a click shows it at once. Nothing happens
    /// when it was read in the last minute or is being read already.
    static func prefetch(accountID: String, item: PullRequestItem) {
        let entry = Self.key(accountID, item.id)
        if prefetching[entry] != nil { return }
        if let cached = cache[entry], Date().timeIntervalSince(cached.at) < 60 { return }
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else { return }
        let repo = item.repo, number = item.number, started = Date()
        prefetching[entry] = Task {
            let read = await Task.detached(priority: .utility) {
                try? await GitHubPullRequestDetail.load(repo: repo, number: number, token: token)
            }.value
            // An open page may have read it meanwhile; its read is newer.
            if let read, (cache[entry]?.at ?? .distantPast) < started {
                remember(read, key: entry)
                PullRequestStore.shared.update(with: read)
            }
            prefetching[entry] = nil
        }
    }
}
