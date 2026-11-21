import SwiftUI

/// At the end of the timeline of a session a usage limit stopped, in the shape of the "Stopped" marker
/// (`stoppedMarker`): a hairline on either side of a small pill that says the limit was reached, whose account, and
/// when it resets, with Retry. Under it one quiet row to go on now with the best account that has room left (the
/// logo of the model it goes on with, a model you can change, how much of it is used, "Another model" for the model
/// picker over every agent, account and model, and Go on), then "Resume at reset" (sends "Continue where you left
/// off." once it has) and a banked reset credit.
struct UsageLimitCard: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @EnvironmentObject private var app: AppModel
    let run: WorkspaceRun
    /// The model you picked per account to go on with, instead of the one Nook suggests.
    @State private var picked: [String: String] = [:]

    /// Whether this session shows the limit card instead of the stopped/failed one.
    static func shows(_ run: WorkspaceRun) -> Bool { run.limitedAt != nil && !run.status.isActive }

    var body: some View {
        if Self.shows(run) {
            let auto = run.autoResume == true
            VStack(spacing: NookTheme.Spacing.sm) {
                marker(auto: auto)
                VStack(spacing: NookTheme.Spacing.sm) {
                    offer(suggestions().first)
                    // Also without a known reset: Nook then tries again now and then until the limit lets it through.
                    Toggle(isOn: Binding(get: { auto }, set: { workspace.setAutoResume(run.id, $0) })) {
                        Text(tr("ws.limit.autoResume"))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                    .compactSwitch(.mini)
                    .tint(NookTheme.amber)
                    // A banked reset credit of this account frees it now, instead of waiting for the reset.
                    if let profile = app.profiles.profile(id: run.profileID) {
                        ResetCreditRow(profile: profile)
                    }
                }
                .frame(maxWidth: 560)
            }
            .padding(.vertical, NookTheme.Spacing.sm)
        }
    }

    /// "⏳ Usage limit reached · Claude Code · Work · Resets at 20:10 (in 1h 16m)  Retry": the stopped marker's pill,
    /// the reset in amber. Without the account when the row is too narrow.
    private func marker(auto: Bool) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            NookDivider()
            HStack(spacing: NookTheme.Spacing.sm) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: "hourglass")
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.amber)
                    TimelineView(.nookTicks(every: 30)) { context in
                        let when = line(now: context.date, auto: auto)
                        ViewThatFits(in: .horizontal) {
                            markerText([tr("ws.limit.title"), accountWords(run.provider, profileID: run.profileID)], when: when)
                            markerText([tr("ws.limit.title")], when: when)
                            markerText([], when: when)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                // The limit may already be free (or the reset was early): try the turn again now.
                NookGhostButton(title: tr("ws.action.retry"), compact: true, height: 24) { workspace.retry(run.id) }
            }
            .padding(.leading, NookTheme.Spacing.lg)
            .padding(.trailing, NookTheme.Spacing.xs)
            .padding(.vertical, NookTheme.Spacing.xs)
            .cardBackground(NookTheme.well, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.card)
            .layoutPriority(1)
            NookDivider()
        }
    }

    /// The pill's words: what happened and whose account, then when it resets in amber.
    private func markerText(_ words: [String], when: String) -> some View {
        (Text(words.map { $0 + " · " }.joined()).foregroundStyle(NookTheme.textSecondary)
            + Text(when).foregroundStyle(NookTheme.amber))
            .font(NookTheme.TextStyle.caption)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    /// "[logo] Go on now with Personal  Sonnet 5.5 ⌄ · 20% used     Another model ⌄  Go on": the best account to go on
    /// with, under the logo of the model it goes on with; with none, only "Another model". Always one line: where it is
    /// too narrow, the use goes first, then "Go on now with", then the model menu.
    private func offer(_ option: LimitOption?) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let option {
                ModelMark(model: option.modelName, agent: option.provider.displayName, size: 16)
                    .accountBadge(option.badge, size: 16, ring: NookTheme.well)
                    .padding(.trailing, option.badge == nil ? 0 : 3)
                ViewThatFits(in: .horizontal) {
                    offerWords(option, lead: true, model: true, used: true)
                    offerWords(option, lead: true, model: true, used: false)
                    offerWords(option, lead: false, model: true, used: false)
                    offerWords(option, lead: false, model: false, used: false, truncates: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(tr("ws.limit.goOnOther"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            otherModelMenu.fixedSize()
            if let option {
                SmallPrimaryButton(title: tr("ws.limit.goOn"), compact: true) {
                    _ = workspace.switchProvider(run.id, to: option.provider, profileID: option.profile.id,
                                                 model: option.model, resumeIfLimited: true)
                }
                .fixedSize()
            }
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        .cardBackground(NookTheme.well, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.card)
    }

    /// The offer's words on one line, each part at its own width: "Go on now with", the account, its model as a menu,
    /// and "· 20% used"; the last form cuts the account's name short when even that is too wide.
    private func offerWords(_ option: LimitOption, lead: Bool, model: Bool, used: Bool, truncates: Bool = false) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if lead {
                Text(tr("ws.limit.goOnWith")).foregroundStyle(NookTheme.textSecondary)
            }
            Text(option.sameAgent ? AccountLabel.name(option.profile, app: app) : option.title)
                .fontWeight(.medium)
                .foregroundStyle(NookTheme.textStrong)
            if model {
                ComposerDropdown(width: ModelPickerStyle.width) {
                    LimitMenuLabel(text: option.modelName)
                } content: {
                    AgentModelPicker(providers: [option.provider], provider: option.provider, profileID: option.profile.id,
                                     model: option.model, showsAccounts: false, offersAuto: false) { _, _, model in
                        if let model { picked[option.profile.id] = model }
                    }
                }
            }
            if used, let fraction = option.usedFraction {
                Text("· " + tr("ws.limit.usedShort", Int((fraction * 100).rounded())))
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .font(NookTheme.TextStyle.detail)
        .lineLimit(1)
        // The narrowest form cuts the account's name short instead of running past the row.
        .fixedSize(horizontal: !truncates, vertical: false)
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
            let clock = AgentFormat.upcoming(due, now: now)
            return tr("ws.limit.retriesAt", clock, AgentPathFormat.duration(due.timeIntervalSince(now)))
        }
        if reset <= now { return auto ? tr("ws.limit.resumingSoon") : tr("ws.limit.free") }
        let clock = AgentFormat.upcoming(reset, now: now)
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
        .padding(.vertical, NookTheme.Spacing.xxs)
        .roundedBackground(hovering ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.chip)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The logo of a model: its maker's mark when its name says it (Claude, GPT, Kimi, …), else the agent's logo.
struct ModelMark: View {
    let model: String
    let agent: String
    var size: CGFloat = 16

    var body: some View {
        if let logo = BrandLogo.forName(model) {
            BrandMark(logo: logo, size: size)
        } else {
            AgentLogo(agent: agent, size: size)
        }
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
