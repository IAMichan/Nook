import SwiftUI

// CLIProxyAPI hubs as a source of limits: a hub's accounts with the windows its rate limit headers carry, in the usage
// modal (read-only) and in Settings › Coding agents (with adding and removing). Reuses `UsageLimitRows`, so a hub's
// account looks like any other account. See `CLIProxyHub` for what Nook reads from a hub, and what it does not.

extension CLIProxyAccount {
    /// The coding agent the hub's provider name stands for; nil for one Nook has no agent for.
    var agentKind: AgentKind? {
        switch provider {
        case "claude": return .claude
        case "codex": return .codex
        case "antigravity": return .antigravity
        case "gemini", "gemini-cli": return .gemini
        case "xai", "grok": return .grok
        default: return nil
        }
    }

    /// The windows the hub saw, as the usage views draw them. A window whose reset has passed is idle again, as for the
    /// accounts Nook reads itself (`QuotaService.settled`).
    @MainActor
    func limits(now: Date = Date()) -> [QuotaLimit] {
        windows(now: now).map { window in
            let label: String
            switch window.key {
            case "five_hour": label = tr("agents.fiveHour")
            case "seven_day": label = tr("agents.week")
            default: label = tr("cliproxy.window")
            }
            let limit = QuotaLimit(label: label, percent: window.usedPercent, resetsAt: window.resetsAt, duration: window.duration)
            return window.resetsAt == nil ? limit : QuotaService.settled(limit, now: now)
        }
    }
}

/// Every hub with its accounts. `editable` adds the remove button of a hub (Settings); the usage modal only shows.
struct CLIProxyHubsList: View {
    @ObservedObject var usage: CLIProxyUsage
    var editable: Bool
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxl) {
            ForEach(usage.hubs) { hub in
                CLIProxyHubBlock(hub: hub, snapshot: usage.snapshots[hub.id], editable: editable, now: now) { usage.remove(hub) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One hub: its name and address over a row per account, with why the last read failed when it did.
private struct CLIProxyHubBlock: View {
    let hub: CLIProxyHub
    let snapshot: CLIProxyUsage.Snapshot?
    let editable: Bool
    let now: Date
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.lg) {
                Image(icon: "server.rack")
                    .font(NookTheme.font(14, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(hub.name)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(hub.url)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if editable {
                    ConfirmedButton(symbol: "trash", title: tr("cliproxy.remove"), question: tr("cliproxy.removeQuestion", hub.name),
                                    detail: tr("cliproxy.removeDetail"), action: remove)
                        .help(tr("cliproxy.remove"))
                }
            }
            if let problem = snapshot?.problem {
                Text(Self.text(problem))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot, snapshot.readAt != nil {
                if snapshot.accounts.isEmpty {
                    Text(tr("cliproxy.noAccounts"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                } else {
                    ForEach(snapshot.accounts) { account in
                        CLIProxyAccountRow(account: account, now: now)
                    }
                }
            } else if snapshot?.problem == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    static func text(_ problem: CLIProxyUsage.Problem) -> String {
        switch problem {
        case .noKey: return tr("cliproxy.problem.noKey")
        case .badAddress: return tr("cliproxy.problem.badAddress")
        case .insecureAddress: return tr("cliproxy.problem.insecure")
        case .rejectedKey: return tr("cliproxy.problem.rejectedKey")
        case .unreachable: return tr("cliproxy.problem.unreachable")
        case .notAHub: return tr("cliproxy.problem.notAHub")
        }
    }
}

/// One account of a hub: logo, name and whether the hub takes requests to it, then its windows.
private struct CLIProxyAccountRow: View {
    let account: CLIProxyAccount
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.lg) {
                if let kind = account.agentKind {
                    AgentLogo(kind, size: 22)
                } else {
                    Image(icon: "person.crop.circle")
                        .font(NookTheme.font(18, .regular))
                        .foregroundStyle(NookTheme.textSecondary)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(account.name)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(state.text).foregroundStyle(state.color)
                        Text("·").foregroundStyle(NookTheme.textSecondary)
                        Text(tr("cliproxy.requests", account.succeeded, account.failed)).foregroundStyle(NookTheme.textSecondary)
                    }
                    .font(NookTheme.TextStyle.detail)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            UsageLimitRows(limits: account.limits(now: now), unavailable: tr("cliproxy.noLimits"), now: now)
        }
    }

    private var state: (text: String, color: Color) {
        if account.disabled { return (tr("cliproxy.state.disabled"), NookTheme.textSecondary) }
        if !account.isAvailable(now: now) {
            if let retry = account.retryAt, retry > now {
                return (tr("cliproxy.state.holding", AgentFormat.compactDuration(retry.timeIntervalSince(now))), NookTheme.amber)
            }
            return (tr("cliproxy.state.unavailable"), NookTheme.amber)
        }
        return (tr("cliproxy.state.ready"), NookTheme.mint)
    }
}

/// Adds a hub: a name (optional), its address and its management key (`remote-management.secret-key` in the hub's config).
/// The key goes to the Keychain and to the hub's own address only.
struct CLIProxyAddForm: View {
    @ObservedObject var usage: CLIProxyUsage
    @State private var label = ""
    @State private var address = ""
    @State private var key = ""
    @State private var problem: CLIProxyUsage.Problem?

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            TextField(tr("cliproxy.labelPlaceholder"), text: $label, prompt: Text(tr("cliproxy.labelPlaceholder")).foregroundStyle(NookTheme.textTertiary))
                .settingsField()
            TextField(tr("cliproxy.addressPlaceholder"), text: $address, prompt: Text(tr("cliproxy.addressPlaceholder")).foregroundStyle(NookTheme.textTertiary))
                .settingsField()
                .onSubmit(add)
            HStack {
                SecureField(tr("cliproxy.keyPlaceholder"), text: $key, prompt: Text(tr("cliproxy.keyPlaceholder")).foregroundStyle(NookTheme.textTertiary))
                    .settingsField()
                    .onSubmit(add)
                Button(tr("cliproxy.add"), action: add)
                    .buttonStyle(.nookProminent)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                SettingNote(CLIProxyHubBlock.text(problem), tone: .error)
            }
        }
    }

    private func add() {
        problem = usage.add(label: label, address: address, key: key)
        guard problem == nil else { return }
        label = ""
        address = ""
        key = ""
    }
}
