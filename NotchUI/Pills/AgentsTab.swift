import SwiftUI
import AppKit

/// Je agents in één blik. Links: wat nu draait, je eerdere sessies en je accounts (Claude, Codex) met hun limieten.
/// Rechts: het gekozen item in detail. Een account toont gebruik en recente sessies; een eerdere sessie kun je hervatten.
struct AgentsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @State private var draft = ""
    /// Welke koppelingen in Instellingen › Agents aan staan. Ingelezen bij openen, niet bij elke hertekening.
    @State private var linked: Set<AgentConfigInstaller.Target> = []
    @State private var copiedID: String?

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case account(AgentKind)
    }

    var body: some View {
        let live = app.agentSessions
        let past = app.demoMode ? [] : Array(app.history.sessions.prefix(40))
        // Alle accounts, ook als de agent er nog niet is: dan installeert en koppelt één klik hem.
        let accounts = app.demoMode ? [] : AgentKind.allCases
        Group {
            if live.isEmpty && past.isEmpty && accounts.isEmpty {
                emptyState
            } else {
                content(live: live, past: past, accounts: accounts)
            }
        }
        .onAppear {
            app.hub.refreshDetected()
            app.history.refresh()
            refreshLinks()
        }
        .onChange(of: viewModel.selectedAgentID) { _, _ in refreshLinks() }
        .onChange(of: app.agentConnect) { _, _ in refreshLinks() }
        // Zolang de tab open is, blijven sessies en gebruik bij.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                app.history.refresh()
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ik zie nu geen agent draaien")
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text("Ik zoek op je Mac naar Claude Code, Codex, Gemini CLI, Aider en OpenCode. Start er een in de terminal en hij staat hier binnen tien seconden. Koppel hem via Instellingen › Agents voor voortgang en om te vragen of iets mag.")
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            NookGhostButton(title: "Open instellingen") { app.openSettings(section: .agents) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Indeling

    @ViewBuilder
    private func content(live: [AgentSession], past: [PastSession], accounts: [AgentKind]) -> some View {
        let selection = resolve(live: live, past: past, accounts: accounts)

        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        liveList(live, selection: selection)
                        if !past.isEmpty {
                            SectionHeader(title: "Eerder", trailing: app.history.loading ? "even kijken…" : nil)
                                .padding(.top, 12)
                            ForEach(past) { session in
                                PastRow(session: session, selected: isSelected(session, selection)) {
                                    viewModel.selectedAgentID = "past:" + session.id
                                }
                            }
                        }
                    }
                }
                if !accounts.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(accounts) { kind in
                            AccountChip(
                                kind: kind,
                                account: app.history.accounts[kind],
                                status: chipStatus(kind),
                                limits: limits(for: kind),
                                selected: isSelected(kind, selection)
                            ) {
                                viewModel.selectedAgentID = "account:" + kind.rawValue
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .frame(width: 240)

            Rectangle().fill(NookTheme.line).frame(width: 1)

            switch selection {
            case .live(let session): liveDetail(session)
            case .past(let session): pastDetail(session)
            case .account(let kind): accountDetail(kind)
            }
        }
    }

    @ViewBuilder
    private func liveList(_ live: [AgentSession], selection: Selection) -> some View {
        let waiting = live.filter { $0.status == .waiting }.count
        SectionHeader(title: "Nu actief", trailing: live.isEmpty ? nil : (waiting > 0 ? "\(waiting) wacht op jou" : "\(live.count)"))
        if live.isEmpty {
            Text("Geen agent aan het werk")
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        ForEach(live) { session in
            AgentRow(session: session, selected: isSelected(session, selection)) {
                viewModel.selectedAgentID = session.id
            }
        }
    }

    /// Wat er rechts staat. Valt terug op iets zinnigs als het gekozen item er niet meer is.
    private func resolve(live: [AgentSession], past: [PastSession], accounts: [AgentKind]) -> Selection {
        let id = viewModel.selectedAgentID
        if id.hasPrefix("account:"), let kind = AgentKind(rawValue: String(id.dropFirst(8))), accounts.contains(kind) {
            return .account(kind)
        }
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            if let session = app.history.sessions.first(where: { $0.id == key }) { return .past(session) }
        }
        if let session = live.first(where: { $0.id == id }) { return .live(session) }
        if let first = live.first { return .live(first) }
        if let kind = accounts.first(where: { app.history.accounts[$0] != nil })
            ?? accounts.first(where: { app.history.installed.contains($0) }) ?? accounts.first { return .account(kind) }
        return .past(past[0])
    }

    private func isSelected(_ session: AgentSession, _ selection: Selection) -> Bool {
        if case .live(let selected) = selection { return selected.id == session.id }
        return false
    }

    private func isSelected(_ session: PastSession, _ selection: Selection) -> Bool {
        if case .past(let selected) = selection { return selected.id == session.id }
        return false
    }

    private func isSelected(_ kind: AgentKind, _ selection: Selection) -> Bool {
        if case .account(let selected) = selection { return selected == kind }
        return false
    }

    // MARK: Gegevens

    private func refreshLinks() {
        var result: Set<AgentConfigInstaller.Target> = []
        for target in AgentConfigInstaller.Target.allCases where AgentConfigInstaller.state(of: target) == .installed {
            result.insert(target)
        }
        if result != linked { linked = result }
    }

    /// De 5-uurs- en weeklimiet van het abonnement, als de agent die doorgaf.
    private func limits(for kind: AgentKind) -> [UsageLimit] {
        switch kind {
        case .claude:
            guard let usage = app.hub.planUsage else { return [] }
            return [
                usage.fiveHour.map { UsageLimit(label: "5 uur", percent: $0.effectivePercent, resetsAt: $0.resetsAt) },
                usage.sevenDay.map { UsageLimit(label: "Week", percent: $0.effectivePercent, resetsAt: $0.resetsAt) }
            ].compactMap { $0 }
        case .gemini:
            return []
        case .codex:
            guard let snapshot = app.codex.snapshot else { return [] }
            return [
                snapshot.fiveHour.map { UsageLimit(label: "5 uur", percent: Double($0.percent()), resetsAt: $0.resetsAt) },
                snapshot.weekly.map { UsageLimit(label: "Week", percent: Double($0.percent()), resetsAt: $0.resetsAt) }
            ].compactMap { $0 }
        }
    }

    private func plan(for kind: AgentKind) -> String {
        if let plan = app.history.accounts[kind]?.plan, !plan.isEmpty { return plan }
        if kind == .codex, let raw = app.codex.snapshot?.planType, !raw.isEmpty {
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
        return ""
    }

    // MARK: Account

    private func accountDetail(_ kind: AgentKind) -> some View {
        let account = app.history.accounts[kind]
        let summary = app.history.usage[kind] ?? AgentUsageSummary()
        let windows = limits(for: kind)
        let recent = Array(app.history.sessions(for: kind).prefix(6))
        let planName = plan(for: kind)

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(kind.name).font(NookTheme.font(15, .semibold)).foregroundStyle(NookTheme.paper)
                        if !planName.isEmpty { Badge(text: planName, color: kind.color) }
                        Spacer()
                        if account != nil {
                            Label("Ingelogd", systemImage: "checkmark.circle.fill")
                                .font(NookTheme.font(12, .semibold))
                                .foregroundStyle(NookTheme.mint)
                        }
                    }
                    Text(accountLine(kind, account))
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                }

                connectBar(kind)

                if windows.isEmpty {
                    limitHint(kind)
                } else {
                    HStack(spacing: 10) {
                        ForEach(windows) { LimitCard(limit: $0) }
                    }
                    if kind == .claude, let updated = app.hub.planUsage?.updated {
                        Text("Bijgewerkt \(AgentFormat.relative(updated)), uit de statusregel van Claude Code")
                            .font(NookTheme.font(11))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(.top, -6)
                    }
                }

                if kind != .gemini {
                    HStack(alignment: .bottom, spacing: 10) {
                        StatCard(title: "Vandaag", value: TokenTally.format(summary.today.total) + " tokens",
                                 detail: AgentFormat.count(summary.sessionsToday, "sessie", "sessies"))
                        StatCard(title: "Laatste 7 dagen", value: TokenTally.format(summary.week.total) + " tokens",
                                 detail: AgentFormat.count(summary.sessionsWeek, "sessie", "sessies"))
                        DayBars(days: summary.perDay, color: kind.color)
                    }
                }

                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader(title: "Recente sessies", trailing: nil)
                        ForEach(recent) { session in
                            PastRow(session: session, selected: false, showAgent: false) {
                                viewModel.selectedAgentID = "past:" + session.id
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func accountLine(_ kind: AgentKind, _ account: AgentAccount?) -> String {
        guard let account else {
            return app.history.executables[kind] == nil ? "Nog niet op deze Mac" : "Nog niet ingelogd"
        }
        var parts = [account.name]
        if !account.organization.isEmpty { parts.append(account.organization) }
        if kind == .claude, app.settings.provider == .claudeCode, !app.settings.useLocal { parts.append("ook Nooks brein") }
        return parts.joined(separator: " · ")
    }

    /// Geen limieten bekend: zeg waarom en hoe je ze wel ziet.
    @ViewBuilder
    private func limitHint(_ kind: AgentKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                if kind == .claude && !linked.contains(.claudeStatusLine) {
                    Text("Zie je 5-uurs- en weeklimiet")
                        .font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
                    Text("Eén klik op Koppel zet de statusregel van Claude Code aan.")
                        .font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary)
                } else if kind == .gemini {
                    Text("Geen limieten bekend")
                        .font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
                    Text("Gemini CLI geeft zijn gebruik niet door. Sessies zie je hier zodra hij gekoppeld is en draait.")
                        .font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary)
                } else {
                    Text("Nog geen limieten ontvangen")
                        .font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
                    Text(kind == .claude
                         ? "Ze verschijnen zodra je Claude Code weer gebruikt (alleen bij Pro en Max)."
                         : "Ze verschijnen zodra je Codex gebruikt met je ChatGPT-account.")
                        .font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if kind == .claude && !linked.contains(.claudeStatusLine) {
                NookGhostButton(title: "Koppel") { app.connect(.claude) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }

    /// Wat er voor deze agent nog ontbreekt.
    private struct Missing {
        var program: Bool
        var login: Bool
        var targets: [AgentConfigInstaller.Target]
        var isEmpty: Bool { !program && !login && targets.isEmpty }
    }

    private func missing(_ kind: AgentKind) -> Missing {
        Missing(
            program: app.history.executables[kind] == nil,
            login: app.history.accounts[kind] == nil,
            targets: kind.targets.filter { !linked.contains($0) }
        )
    }

    private func chipStatus(_ kind: AgentKind) -> String? {
        let gap = missing(kind)
        if gap.program { return "niet geïnstalleerd" }
        if gap.login { return "niet ingelogd" }
        if !gap.targets.isEmpty { return "nog koppelen" }
        return nil
    }

    /// Eén knop die alles voor dit account regelt: installeren, inloggen en de koppelingen in de notch.
    private func connectBar(_ kind: AgentKind) -> some View {
        let gap = missing(kind)
        let progress = app.agentConnect[kind]
        let busy = progress?.isBusy == true
        let failed: Bool = { if case .failed? = progress { return true }; return false }()

        let title: String
        let detail: String
        if busy {
            title = progress?.text ?? "Bezig…"
            detail = "Volg de stappen in Terminal. Dit werkt vanzelf bij zodra je klaar bent."
        } else if failed {
            title = "Koppelen lukte niet"
            detail = progress?.text ?? ""
        } else if gap.isEmpty {
            title = "Alles gekoppeld"
            if case .done(let text)? = progress {
                detail = text
            } else {
                detail = kind == .claude ? "Ingelogd, voortgang, goedkeuren en limieten in de notch" : "Ingelogd, voortgang en goedkeuren in de notch"
            }
        } else {
            title = "Koppel \(kind.name) met één klik"
            var parts: [String] = []
            if gap.program { parts.append("installeert \(kind.command)") }
            if gap.login { parts.append("laat je inloggen") }
            if !gap.targets.isEmpty {
                parts.append(kind == .claude ? "zet voortgang, goedkeuren en limieten aan" : "zet voortgang en goedkeuren aan")
            }
            detail = "Nook " + parts.joined(separator: ", ") + "."
        }
        let buttonTitle = gap.program ? "Installeer en koppel" : (gap.login ? "Log in en koppel" : "Koppel")

        return HStack(spacing: 12) {
            Image(systemName: gap.isEmpty && !busy ? "checkmark.circle.fill" : (failed ? "exclamationmark.triangle.fill" : "link"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(gap.isEmpty && !busy ? NookTheme.mint : (failed ? NookTheme.coral : kind.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(detail)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small)
            } else if !gap.isEmpty || failed {
                NookPrimaryButton(title: failed ? "Probeer opnieuw" : buttonTitle) { app.connect(kind) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }

    // MARK: Eerdere sessie

    private func pastDetail(_ session: PastSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title.isEmpty ? "Sessie zonder titel" : session.title)
                        .font(NookTheme.font(15, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(2)
                    Spacer()
                    Text(session.agent.name)
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(session.agent.color)
                }
                Text([session.project, session.branch, session.model].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                StatPill(title: "Laatst actief", value: AgentFormat.relative(session.ended))
                StatPill(title: "Duur", value: AgentFormat.duration(session.duration))
                StatPill(title: "Vragen", value: "\(session.prompts)")
                StatPill(title: "Tokens", value: TokenTally.format(session.tokens.total))
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if !session.lastPrompt.isEmpty {
                        Message(author: "Jij", text: session.lastPrompt, color: NookTheme.textSecondary)
                    }
                    if !session.lastReply.isEmpty {
                        Message(author: session.agent.shortName, text: session.lastReply, color: session.agent.color)
                    }
                    if session.lastPrompt.isEmpty && session.lastReply.isEmpty {
                        Text("Geen berichten in dit transcript.")
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))

            HStack(spacing: 4) {
                NookPrimaryButton(title: "Hervat in Terminal") { app.resume(session) }
                NookGhostButton(title: copiedID == session.id ? "Gekopieerd" : "Kopieer commando") {
                    app.copyResumeCommand(session)
                    copiedID = session.id
                }
                if !session.cwd.isEmpty {
                    NookGhostButton(title: "Open map") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd, isDirectory: true))
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Draaiende sessie

    private func liveDetail(_ session: AgentSession) -> some View {
        let kind = AgentKind(agentName: session.name)
        let target = AgentConfigInstaller.Target.forAgent(named: session.name)
        let isLinked = target.map { linked.contains($0) } ?? false

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.name).font(NookTheme.font(15, .semibold)).foregroundStyle(NookTheme.paper)
                    + Text("  ·  \(session.project)").font(NookTheme.font(15, .medium)).foregroundStyle(NookTheme.textTertiary)
                    Spacer()
                    Text(session.status.label)
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(session.status.color)
                }
                if let kind, !app.demoMode, let line = liveAccountLine(kind) {
                    Button { viewModel.selectedAgentID = "account:" + kind.rawValue } label: {
                        Text(line)
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Bekijk gebruik en eerdere sessies")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.steps) { step in
                    let current = step.id == session.steps.last?.id && step.mark == .running && session.status == .running
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(step.symbol)
                            .foregroundStyle(step.color)
                            .frame(width: 12)
                        if current {
                            ShimmerText(text: step.text)
                        } else {
                            Text(step.text)
                                .foregroundStyle(Color(hex: 0xC9C7D2))
                        }
                    }
                    .font(NookTheme.font(13))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(session.file)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.bottom, 4)
                ForEach(session.diff) { line in
                    Text(line.text).foregroundStyle(line.color)
                }
                Spacer(minLength: 0)
            }
            .font(NookTheme.mono(11.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))
            .clipped()

            HStack(spacing: 4) {
                if !app.demoMode, let id = session.approvalID, let request = app.hub.approval(id: id) {
                    NookPrimaryButton(title: "Toestaan") { app.hub.decide(id, .allow) }
                    if request.canAlways {
                        NookGhostButton(title: "Altijd") { app.hub.decide(id, .always) }
                    }
                    NookGhostButton(title: "Weigeren") { app.hub.decide(id, .deny) }
                    Spacer()
                    terminalButton(session)
                } else if app.demoMode {
                    if session.status == .waiting {
                        NookPrimaryButton(title: "Toestaan") { viewModel.finish("Toegestaan · npm install draait") }
                        NookGhostButton(title: "Weigeren") { viewModel.show(.idle) }
                    }
                    TextField(
                        "",
                        text: $draft,
                        prompt: Text(session.placeholder).foregroundStyle(NookTheme.textTertiary)
                    )
                    .textFieldStyle(.plain)
                    .font(NookTheme.font(13))
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(NookTheme.field))
                    NookIconButton(systemName: "arrow.up", label: "Versturen", filled: true) { draft = "" }
                } else if session.status == .detected {
                    if isLinked {
                        terminalButton(session, primary: true)
                        Text("Start \(session.name) daar opnieuw")
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(.leading, 8)
                    } else {
                        NookPrimaryButton(title: "Koppel \(session.name)") { app.openSettings(section: .agents) }
                        Text("Of typ gewoon verder in de terminal van \(session.name)")
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(.leading, 8)
                    }
                    Spacer(minLength: 0)
                } else {
                    Text(session.placeholder)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                    Spacer()
                    terminalButton(session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "michiel@… · Max · 5 uur 34%": met welk account deze agent werkt.
    private func liveAccountLine(_ kind: AgentKind) -> String? {
        guard let account = app.history.accounts[kind] else { return nil }
        var parts = ["via " + account.name]
        let planName = plan(for: kind)
        if !planName.isEmpty { parts.append(planName) }
        parts += limits(for: kind).map { "\($0.label.lowercased()) \(Int($0.percent.rounded()))%" }
        return parts.joined(separator: " · ") + "  ›"
    }

    @ViewBuilder
    private func terminalButton(_ session: AgentSession, primary: Bool = false) -> some View {
        let title = "Open \(TerminalLauncher.name(for: session.hostBundleID))"
        if primary {
            NookPrimaryButton(title: title) { app.openTerminal(for: session) }
        } else {
            NookGhostButton(title: title) { app.openTerminal(for: session) }
        }
    }
}

// MARK: Opmaak

private enum AgentFormat {
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "EEEEEE"
        return formatter
    }()

    /// "zojuist", "12 min geleden", "vandaag 14:20", "gisteren 09:12", "di 14 okt".
    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "zojuist" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min geleden" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "vandaag \(time.string(from: date))" }
        if calendar.isDateInYesterday(date) { return "gisteren \(time.string(from: date))" }
        return day.string(from: date)
    }

    /// "< 1 min", "12 min", "1u 20m", "3 dagen".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)u" : "\(hours)u \(minutes % 60)m" }
        return "\(hours / 24) dagen"
    }

    /// "reset om 15:40" of "reset do 16 okt".
    static func reset(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        if date.timeIntervalSinceNow < 20 * 3600 { return "reset om \(time.string(from: date))" }
        return "reset \(day.string(from: date))"
    }

    static func weekdayLetter(_ date: Date) -> String { weekday.string(from: date) }

    static func count(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    static func color(percent: Double) -> Color {
        switch percent {
        case ..<60: return NookTheme.mint
        case ..<85: return NookTheme.amber
        default: return NookTheme.coral
        }
    }
}

/// Eén limiet van een abonnement: hoeveel procent op is en wanneer hij weer vol is.
private struct UsageLimit: Identifiable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    var id: String { label }
}

// MARK: Onderdelen

private struct SectionHeader: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(NookTheme.font(11.5, .semibold))
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(NookTheme.font(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NookTheme.line2)
                Capsule().fill(color).frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 4)
    }
}

/// Een account onderin de lijst: naam, met wie je bent ingelogd en hoe vol de limiet zit.
private struct AccountChip: View {
    let kind: AgentKind
    let account: AgentAccount?
    /// Wat er nog ontbreekt ("niet ingelogd"), of nil als alles klaar is.
    let status: String?
    let limits: [UsageLimit]
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let highest = limits.map(\.percent).max()
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(kind.color).frame(width: 7, height: 7)
                    Text(kind.shortName)
                        .font(NookTheme.font(12.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                    Text(status ?? account?.name ?? "")
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(status == nil ? NookTheme.textTertiary : NookTheme.amber)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if status != nil {
                        Text("Koppel")
                            .font(NookTheme.font(11, .semibold))
                            .foregroundStyle(NookTheme.ink)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill(NookTheme.paper))
                    } else if let highest {
                        Text(limits.map { "\($0.label == "Week" ? "wk" : "5u") \(Int($0.percent.rounded()))%" }.joined(separator: " · "))
                            .font(NookTheme.mono(10.5, .medium))
                            .foregroundStyle(AgentFormat.color(percent: highest))
                            .fixedSize()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                if let highest {
                    Bar(fraction: highest / 100, color: AgentFormat.color(percent: highest))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : NookTheme.field))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Gebruik, limieten en eerdere sessies van \(kind.name)")
    }
}

private struct LimitCard: View {
    let limit: UsageLimit

    var body: some View {
        let color = AgentFormat.color(percent: limit.percent)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label)
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(NookTheme.mono(15, .semibold))
                    .foregroundStyle(color)
            }
            Bar(fraction: limit.percent / 100, color: color)
            Text(AgentFormat.reset(limit.resetsAt) ?? "nog ruimte genoeg")
                .font(NookTheme.font(11))
                .foregroundStyle(NookTheme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(NookTheme.font(11.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            Text(value)
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(detail)
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }
}

/// Tokens per dag over de laatste week, als zeven staafjes.
private struct DayBars: View {
    let days: [(day: Date, tokens: Int)]
    let color: Color

    var body: some View {
        let peak = max(1, days.map { $0.tokens }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(days.indices, id: \.self) { index in
                let entry = days[index]
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(entry.tokens > 0 ? color.opacity(index == days.count - 1 ? 1 : 0.6) : NookTheme.line2)
                        .frame(width: 10, height: max(3, 40 * CGFloat(entry.tokens) / CGFloat(peak)))
                    Text(AgentFormat.weekdayLetter(entry.day))
                        .font(NookTheme.font(9.5))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .help("\(TokenTally.format(entry.tokens)) tokens")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 74)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }
}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(NookTheme.font(10.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            Text(value)
                .font(NookTheme.font(12.5, .semibold))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(NookTheme.field))
    }
}

private struct Message: View {
    let author: String
    let text: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(author)
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(NookTheme.font(12.5))
                .foregroundStyle(Color(hex: 0xC9C7D2))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct PastRow: View {
    let session: PastSession
    let selected: Bool
    var showAgent = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(showAgent ? session.agent.color.opacity(0.8) : NookTheme.line2)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "Sessie zonder titel" : session.title)
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(NookTheme.paper.opacity(0.92))
                        .lineLimit(1)
                    Text("\(session.project) · \(AgentFormat.relative(session.ended)) · \(TokenTally.format(session.tokens.total)) tokens")
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(NookTheme.font(13.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                    Text("\(session.project) · \(session.status.label)")
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// De stap waar de agent nu mee bezig is: een lichtglans die over de tekst schuift.
private struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x8A8896), location: 0),
                            .init(color: Color(hex: 0x8A8896), location: max(0, phase - 0.15)),
                            .init(color: NookTheme.paper, location: phase),
                            .init(color: Color(hex: 0x8A8896), location: min(1, phase + 0.15)),
                            .init(color: Color(hex: 0x8A8896), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}
