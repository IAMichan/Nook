import SwiftUI

/// At the end of the timeline of a session a usage limit stopped, in the place and shape of the "You stopped the agent"
/// card (`recovery`): what happened and when the limit resets beside Retry, then the accounts with room left to go on
/// with at once (best first, each with a model you can change and how much of it is used), "Another model" (the one
/// model picker, every agent, account and model), and "Resume at reset" (sends "Continue where you left off." once it has).
struct UsageLimitCard: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @EnvironmentObject private var app: AppModel
    let run: WorkspaceRun
    /// The model you picked per account to go on with, instead of the one Nook suggests.
    @State private var picked: [String: String] = [:]

    /// At most this many accounts to go on with: the best ones; "Another model" has every account.
    private static let shownOptions = 3

    /// Whether this session shows the limit card instead of the stopped/failed one.
    static func shows(_ run: WorkspaceRun) -> Bool { run.limitedAt != nil && !run.status.isActive }

    var body: some View {
        if Self.shows(run) {
            let auto = run.autoResume == true
            let options = Array(suggestions().prefix(Self.shownOptions))
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                AdaptiveActionRow(spacing: 10, alignment: .top) {
                    header(auto: auto)
                } actions: {
                    // The limit may already be free (or the reset was early): try the turn again now.
                    NookGhostButton(title: tr("ws.action.retry")) { workspace.retry(run.id) }
                        .help(tr("ws.action.retry.help"))
                }
                NookDivider()
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(tr(options.isEmpty ? "ws.limit.goOnOther" : "ws.limit.goOnWith"))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        otherModelMenu
                    }
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    ForEach(Array(options.enumerated()), id: \.element.profile.id) { index, option in
                        LimitOptionRow(option: option, best: index == 0, pickModel: { model in
                            picked[option.profile.id] = model
                        }) {
                            _ = workspace.switchProvider(run.id, to: option.provider, profileID: option.profile.id,
                                                         model: option.model, resumeIfLimited: true)
                        }
                    }
                }
                NookDivider()
                // Also without a known reset: Nook then tries again now and then until the limit lets it through.
                Toggle(isOn: Binding(get: { auto }, set: { workspace.setAutoResume(run.id, $0) })) {
                    Text(tr("ws.limit.autoResume"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(NookTheme.amber)
                .help(tr("ws.limit.resumeHelp"))
                // A banked reset credit of this account frees it now, instead of waiting for the reset.
                if let profile = app.profiles.profile(id: run.profileID) {
                    ResetCreditRow(profile: profile)
                }
            }
            .padding(NookTheme.Spacing.md)
            .cardBackground(NookTheme.surface, stroke: NookTheme.amber.opacity(0.3), radius: NookTheme.Radius.card)
        }
    }

    /// "⌛ Usage limit reached", whose account is at its limit, when it resets, and its 5-hour and weekly windows: laid
    /// out as the stopped and failed cards are.
    private func header(auto: Bool) -> some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            BannerMark(symbol: "hourglass", tint: NookTheme.amber)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("ws.limit.title")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Text(tr("ws.limit.accountAt", accountWords(run.provider, profileID: run.profileID)))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.nookTicks(every: 30)) { context in
                    Text(line(now: context.date, auto: auto))
                        .font(NookTheme.TextStyle.detail)
                        .monospacedDigit()
                        .foregroundStyle(NookTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Which window ran out (5 hours or the week) and how full the other one is.
                if let profile = app.profiles.profile(id: run.profileID) {
                    let own = QuotaLimit.perWindow(app.quota.limits(for: profile), model: run.model)
                    if !own.isEmpty {
                        LimitWindowMeters(limits: own).padding(.top, NookTheme.Spacing.xs)
                    }
                }
            }
        }
    }

    /// "Another model ⌄": the one model picker over every agent and account this session may move to. Another account
    /// or agent takes the session there with a summary and goes on; another model of this account goes on right away.
    private var otherModelMenu: some View {
        let idle = workspace.canTransfer(run.id)
        let allowed = app.connectedProviders(in: run.projectPath)
        let providers = idle ? (allowed.contains(run.provider) ? allowed : [run.provider] + allowed) : [run.provider]
        return ComposerDropdown(width: ModelPickerStyle.width) {
            LimitMenuLabel(text: tr("ws.limit.otherModel"), symbol: "cpu")
        } content: {
            AgentModelPicker(providers: providers, provider: run.provider, profileID: run.profileID,
                             model: run.autoModel == true ? AutoModel.id : run.model, showsAccounts: idle) { provider, accountID, option in
                let profileID = accountID ?? (provider == run.provider ? run.profileID
                    : app.connectedProfiles(for: provider).first?.id ?? run.profileID)
                let model = option ?? (provider == run.provider ? run.model : workspace.settings.model(for: provider))
                // A model of the same account changes from the next turn: that turn is the one the limit stopped.
                if case .applyOnNextTurn = workspace.applySelection(run.id, provider: provider, profileID: profileID,
                                                                     model: model, resumeIfLimited: true) {
                    _ = workspace.send(run.id, text: UsageLimits.resumeMessage)
                }
            }
        }
        .help(tr("ws.limit.otherModelHelp"))
    }

    /// "Claude Code · Personal": the agent, with the account when the agent has several.
    private func accountWords(_ provider: RunProvider, profileID: String) -> String {
        guard let profile = app.profiles.profile(id: profileID), app.connectedProfiles(for: provider).count > 1 else {
            return provider.displayName
        }
        return provider.displayName + " · " + AccountLabel.name(profile, app: app)
    }

    /// The other accounts with room left (`LimitAdvisor.options`, else the least used ones not full yet), each with the model the session would go on with:
    /// the model in use on another account of this agent, the one set for that agent in Settings on another agent.
    private func suggestions() -> [LimitOption] {
        var states: [LimitState] = []
        var profiles: [String: AgentProfile] = [:]
        var windows: [String: [QuotaLimit]] = [:]
        for provider in app.connectedProviders where workspace.executable(provider) != nil {
            for profile in app.connectedProfiles(for: provider) {
                let limits = app.quota.limits(for: profile)
                windows[profile.id] = limits
                let fraction = limits.map(\.percent).max().map { $0 / 100 }
                states.append(LimitState(provider: provider, profileID: profile.id, usedFraction: limits.isEmpty ? nil : fraction,
                                         resetAt: limits.compactMap(\.resetsAt).min()))
                profiles[profile.id] = profile
            }
        }
        // This session's own account counts as full: it hit the limit.
        if let index = states.firstIndex(where: { $0.provider == run.provider && $0.profileID == run.profileID }) {
            states[index].usedFraction = max(states[index].usedFraction ?? 0, 1)
        }
        guard workspace.canTransfer(run.id) else { return [] }
        // With no account that has room left, still propose the least used one that is not full yet.
        let current = (provider: run.provider, profileID: run.profileID)
        let roomy = LimitAdvisor.options(states: states, current: current, now: Date())
        let picks = roomy.isEmpty ? LimitAdvisor.fallbacks(states: states, current: current, now: Date()) : roomy
        return picks.compactMap { pick in
            guard let profile = profiles[pick.profileID] else { return nil }
            let model = picked[profile.id] ?? (pick.sameAgent ? run.model
                : workspace.settings.sessionDefaults(for: run.projectPath).model(for: pick.provider))
            let name = modelName(model, provider: pick.provider, profileID: profile.id)
            return LimitOption(provider: pick.provider, profile: profile, sameAgent: pick.sameAgent,
                               usedFraction: pick.usedFraction,
                               limits: QuotaLimit.perWindow(windows[profile.id] ?? [], model: name), model: model,
                               modelName: name,
                               title: accountWords(pick.provider, profileID: profile.id),
                               badge: AccountTag.badge(profile, app: app))
        }
    }

    /// The model by name; with none chosen, the agent's default by name when Nook knows it.
    private func modelName(_ model: String, provider: RunProvider, profileID: String) -> String {
        if !model.isEmpty, model != AutoModel.id { return app.modelMenuName(model, for: provider, profileID: profileID) }
        return workspace.modelMenu(for: provider, profileID: profileID).choices.first(where: \.isDefault)?.name
            ?? app.modelName(model, for: provider, profileID: profileID)
    }

    private func line(now: Date, auto: Bool) -> String {
        guard let reset = run.limitResetAt else {
            guard auto, let due = workspace.limitResumeDue(run) else { return tr("ws.limit.unknown") }
            if due <= now { return tr("ws.limit.resumingSoon") }
            let clock = due.formatted(date: Calendar.current.isDateInToday(due) ? .omitted : .abbreviated, time: .shortened)
            return tr("ws.limit.retriesAt", clock, AgentPathFormat.duration(due.timeIntervalSince(now)))
        }
        if reset <= now { return auto ? tr("ws.limit.resumingSoon") : tr("ws.limit.free") }
        let clock = reset.formatted(date: Calendar.current.isDateInToday(reset) ? .omitted : .abbreviated, time: .shortened)
        let wait = AgentPathFormat.duration(reset.timeIntervalSince(now))
        return auto ? tr("ws.limit.resumesAt", clock, wait) : tr("ws.limit.resetsAt", clock, wait)
    }
}

/// An account to go on with after a usage limit, as `UsageLimitCard` offers it.
struct LimitOption {
    let provider: RunProvider
    let profile: AgentProfile
    let sameAgent: Bool
    let usedFraction: Double?
    /// The account's windows, one per window ("5 hours", "Week"); empty when the agent reports none.
    let limits: [QuotaLimit]
    /// The model the session goes on with there ("" leaves it to the agent), and its name.
    let model: String
    let modelName: String
    /// "Claude Code · Work".
    let title: String
    let badge: AccountTag?
}

/// One account in the usage limit card: its logo with the account's badge, the agent and account, the model it goes on
/// with (a click opens the model picker for that account) and what goes along, its 5-hour and weekly windows
/// (`LimitWindowMeters`), and "Go on". The best one is lifted and its button is the main one.
struct LimitOptionRow: View {
    let option: LimitOption
    let best: Bool
    let pickModel: (String) -> Void
    let choose: () -> Void

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            AgentLogo(agent: option.provider.displayName, size: 16)
                .accountBadge(option.badge, size: 16, ring: best ? NookTheme.rowSelected : NookTheme.surface)
                .padding(.trailing, option.badge == nil ? 0 : 3)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(option.title)
                    .font(NookTheme.TextStyle.body)
                    .fontWeight(.medium)
                    .foregroundStyle(NookTheme.textStrong)
                    .lineLimit(1)
                HStack(spacing: NookTheme.Spacing.xs) {
                    ComposerDropdown(width: ModelPickerStyle.width) {
                        LimitMenuLabel(text: option.modelName)
                    } content: {
                        AgentModelPicker(providers: [option.provider], provider: option.provider, profileID: option.profile.id,
                                         model: option.model, showsAccounts: false, offersAuto: false) { _, _, model in
                            if let model { pickModel(model) }
                        }
                    }
                    .help(tr("ws.limit.modelHelp"))
                    Text("· " + tr(option.sameAgent ? "ws.limit.carrySame" : "ws.limit.carryOther"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            LimitWindowMeters(limits: option.limits)
            if best {
                SmallPrimaryButton(title: tr("ws.limit.goOn"), action: choose)
            } else {
                SmallGhostButton(title: tr("ws.limit.goOn"), action: choose)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.sm)
        .roundedBackground(best ? NookTheme.rowSelected : Color.clear, radius: NookTheme.Radius.control)
        .help(tr(option.sameAgent ? "ws.limit.switchHelpSame" : "ws.limit.switchHelp"))
    }
}

/// A quiet menu in the usage limit card: an optional symbol, its text and a chevron, brighter under the pointer.
struct LimitMenuLabel: View {
    let text: String
    var symbol: String? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if let symbol { Image(icon: symbol).font(NookTheme.font(10, .semibold)) }
            Text(text).lineLimit(1)
            Image(icon: "chevron.down").font(NookTheme.font(8, .bold))
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
        .padding(.horizontal, NookTheme.Spacing.xs)
        .padding(.vertical, 2)
        .roundedBackground(hovering ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.chip)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The mark at the start of a card at the end of the timeline (usage limit, stopped, failed): its symbol in a soft circle of its tint.
struct BannerMark: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(icon: symbol)
            .font(NookTheme.font(12, .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.opacity(0.14)))
    }
}
