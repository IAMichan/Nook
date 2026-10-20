import SwiftUI

/// Nook's home and usage for the iPhone companion: the same Today rows, agenda, player and plan limits as the notch and
/// Settings › Usage, read from the same places so the phone and the Mac never disagree.
extension CompanionServer {
    // MARK: Home

    func home(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        refreshQuotasNow(app)
        let now = Date()
        let lines = app.todayItems.prefix(8).map { item in
            HomeDigest.Line(id: item.id, title: CompanionPolicy.clip(item.title, limit: 200),
                            subtitle: CompanionPolicy.clip(item.subtitle, limit: 200), icon: Self.icon(item.logo), tone: Self.tone(item.color))
        }
        let events = app.upcoming.filter { $0.end > now }.prefix(8).map { event in
            HomeDigest.Event(id: event.id, title: CompanionPolicy.clip(event.title, limit: 200), start: event.start.timeIntervalSince1970,
                             end: event.end.timeIntervalSince1970, location: CompanionPolicy.clip(event.location, limit: 120),
                             calendar: event.calendar)
        }
        let track = app.nowPlaying.current.map { info in
            HomeDigest.Track(title: info.title, artist: info.artist, album: info.album, app: info.app, playing: info.isPlaying,
                             position: info.estimatedPosition(at: now), duration: Double(info.duration))
        }
        let digest = HomeDigest(lines: Array(lines), events: Array(events), suggestions: app.startSuggestions.prefix(4).map(\.text),
                                track: track, accounts: accounts(app))
        return CompanionResponse(id: request.id, ok: true, sessions: digests(app.workspace), home: digest)
    }

    /// The player's buttons. Only what the notch's player offers; nothing else on the Mac is controlled from here.
    func music(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        let command: NowPlayingService.Command
        switch request.text {
        case "playpause": command = .playPause
        case "next": command = .next
        case "previous": command = .previous
        default: return .failure(request.id, .badRequest)
        }
        guard app.nowPlaying.current != nil else { return .failure(request.id, .unknownItem) }
        app.nowPlaying.control(command)
        audit("music", request.text ?? "")
        return home(request, app: app)
    }

    private static func icon(_ logo: TodayItem.Logo?) -> String {
        switch logo {
        case .source(let id): return "source:" + id
        case .agent(let name): return "agent:" + name
        case .symbol(let name): return "symbol:" + name
        case nil: return "symbol:circle.fill"
        }
    }

    /// The state colors keep their meaning on the phone; anything else is Nook's own iris.
    private static func tone(_ color: Color) -> String {
        if color == NookTheme.amber { return "amber" }
        if color == NookTheme.coral || color == NookTheme.coralSoft { return "coral" }
        if color == NookTheme.mint || color == NookTheme.mintSoft { return "mint" }
        return "iris"
    }

    // MARK: Usage

    func usage(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        refreshQuotasNow(app)
        let range = request.item.flatMap(UsageRange.init(rawValue:)) ?? .week
        let report = UsageReport.make(runs: app.workspace.runs, filter: UsageReport.Filter(range: range, provider: nil, model: nil, project: nil))
        let digest = UsageDigest(
            accounts: accounts(app), range: range.rawValue,
            sessions: report.sessions, completed: report.completed, failed: report.failed, running: report.running,
            inputTokens: report.inputTokens, outputTokens: report.outputTokens,
            cacheTokens: report.cacheReadTokens + report.cacheWriteTokens, cost: report.reportedCostUSD,
            days: report.days.map { .init(day: $0.day.timeIntervalSince1970, agent: $0.provider.displayName, tokens: $0.tokens) },
            models: report.rows.prefix(20).map { row in
                .init(agent: row.provider.displayName, model: row.model, sessions: row.sessions,
                      tokens: row.inputTokens + row.outputTokens + row.cacheReadTokens, cost: row.reportedCostUSD)
            })
        return CompanionResponse(id: request.id, ok: true, usage: digest)
    }

    /// Every connected account with the limits it reported, as in Settings › Usage.
    private func accounts(_ app: AppModel) -> [UsageDigest.Account] {
        app.connectedProfiles.map { profile in
            UsageDigest.Account(id: profile.id, agent: profile.kind.shortName, account: AccountLabel.name(profile, app: app),
                                limits: app.quota.limits(for: profile).map { limit in
                                    .init(label: limit.label, percent: limit.percent, resetsAt: limit.resetsAt?.timeIntervalSince1970,
                                          note: limit.note, duration: limit.duration)
                                })
        }
    }

    /// Reads the limits again when the phone looks, at most every two minutes (as a usage view on the Mac does).
    private func refreshQuotasNow(_ app: AppModel) {
        guard Date().timeIntervalSince(QuotaPace.last) > 120 else { return }
        QuotaPace.last = Date()
        app.refreshQuotas()
    }
}

@MainActor
private enum QuotaPace {
    static var last = Date.distantPast
}
