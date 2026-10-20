import SwiftUI
import AppKit

// What Nook used for an answer: where it looked (and whether that succeeded), which sources the answer cites,
// and what you need to know if something could not be read. Plus the source picker and summary of included context.

/// One quiet line under an answer ("Used 3 sources"). Opens to show where Nook looked and what came out of it, with the
/// numbered references the answer cites. It opens by itself when a source could not be read.
struct SourcesDisclosure: View {
    let message: ChatMessage
    /// Retry the answer; only given for the latest answer.
    var onRetry: (() -> Void)? = nil
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var permissions = PermissionMonitor.shared
    @State private var expanded = false

    private enum Status { case found, empty, failed(String), running, context }

    private struct SourceGroup: Identifiable {
        let id: String
        let title: String
        var status: Status
        var queries: [String] = []
        var references: [SourceReference] = []
    }

    private var groups: [SourceGroup] {
        var result: [SourceGroup] = []
        func index(_ title: String) -> Int {
            if let i = result.firstIndex(where: { $0.title == title }) { return i }
            result.append(SourceGroup(id: title, title: title, status: .context))
            return result.count - 1
        }
        // One group per source, even if Nook inspected it more than once.
        var order: [String] = []
        var grouped: [String: [RetrievalStep]] = [:]
        for step in message.retrieval {
            if grouped[step.sourceTitle] == nil { order.append(step.sourceTitle) }
            grouped[step.sourceTitle, default: []].append(step)
        }
        for title in order {
            let steps = grouped[title] ?? []
            let i = index(title)
            result[i].queries = steps.map(\.query).filter { !$0.isEmpty }
            if steps.contains(where: { $0.outcome == .running }) {
                result[i].status = message.streaming ? .running : .failed(tr("chat.sources.interrupted"))
            } else if !steps.contains(where: { if case .found = $0.outcome { return true }; return false }),
                      let failed = steps.compactMap({ step -> String? in if case .failed(let error) = step.outcome { return error }; return nil }).first {
                result[i].status = .failed(failed)
            } else if steps.allSatisfy({ $0.outcome == .empty }) {
                result[i].status = .empty
            } else {
                result[i].status = .found
            }
        }
        for reference in message.references {
            let i = index(SourceCatalog.title(reference.sourceID))
            result[i].references.append(reference)
            if case .context = result[i].status { result[i].status = .found }
        }
        for source in message.sources + message.contextSources { _ = index(source) }
        return result
    }

    private var failedCount: Int {
        groups.filter { if case .failed = $0.status { return true }; return false }.count
    }

    /// Sources that need attention first, then what was used, then the rest.
    private static func rank(_ status: Status) -> Int {
        switch status {
        case .failed: return 0
        case .running: return 1
        case .found: return 2
        case .context: return 3
        case .empty: return 4
        }
    }

    var body: some View {
        let list = groups.enumerated().sorted { (Self.rank($0.element.status), $0.offset) < (Self.rank($1.element.status), $1.offset) }.map(\.element)
        if !list.isEmpty {
            let used = list.filter { if case .found = $0.status { return true }; if case .context = $0.status { return true }; return false }.count
            let failed = failedCount
            let running = list.contains { if case .running = $0.status { return true }; return false }
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() } } label: {
                    HStack(spacing: 7) {
                        iconStack(list)
                        Text(summary(used: used, failed: failed, running: running))
                            .font(NookTheme.font(12, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                        if failed > 0 && !(running && message.streaming) {
                            Text(tr("chat.sources.unread", failed))
                                .font(NookTheme.font(10.5, .semibold))
                                .foregroundStyle(NookTheme.amber)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(NookTheme.amber.opacity(0.12)))
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(NookTheme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(message.scopeLabel.isEmpty ? tr("chat.sources.detailsHelp") : tr("chat.sources.scope", message.scopeLabel))
                .accessibilityLabel(summary(used: used, failed: failed, running: running)
                                    + (failed > 0 ? ", " + tr("chat.sources.unread", failed) : ""))

                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, group in
                            if index > 0 {
                                Rectangle().fill(NookTheme.line2.opacity(0.6)).frame(height: 1).padding(.horizontal, 8)
                            }
                            groupView(group)
                        }
                    }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(NookTheme.field)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NookTheme.line2.opacity(0.7), lineWidth: 1))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .onAppear { if failed > 0 { expanded = true } }
            .onChange(of: failedCount) { _, count in if count > 0 { expanded = true } }
        }
    }

    private func summary(used: Int, failed: Int, running: Bool) -> String {
        if running && message.streaming { return tr("chat.sources.searchingShort") }
        if used == 0 { return tr("chat.sources.nothing").capitalizedFirst }
        return used == 1 ? tr("chat.sources.usedOne") : tr("chat.sources.used", used)
    }

    /// The first few sources' icons, slightly overlapping, so you see at a glance where Nook looked.
    private func iconStack(_ list: [SourceGroup]) -> some View {
        HStack(spacing: -4) {
            ForEach(list.prefix(4)) { group in
                plainIcon(group)
                    .padding(1.5)
                    .background(Circle().fill(NookTheme.graphite))
                    .overlay(Circle().stroke(NookTheme.ink, lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }

    private func groupView(_ group: SourceGroup) -> some View {
        let cited = Citations.used(in: message.text)
        let failure: String? = { if case .failed(let reason) = group.status { return Self.readable(reason) }; return nil }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                sourceIcon(group)
                Text(group.title)
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(failure == nil ? NookTheme.paper.opacity(0.88) : NookTheme.paper)
                Spacer(minLength: 6)
                statusChip(group)
            }
            .help(helpText(group))
            if let failure {
                failureView(failure)
            }
            if !message.streaming && !group.references.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.references) { reference in
                        ReferenceRow(reference: reference, cited: cited.contains(reference.number)) { app.openReference(reference) }
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(failure == nil ? Color.clear : NookTheme.coral.opacity(0.06))
        )
    }

    /// The status of a source as a small chip: green when it was used, red when it could not be read.
    @ViewBuilder
    private func statusChip(_ group: SourceGroup) -> some View {
        HStack(spacing: 4) {
            if case .running = group.status {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 9, height: 9)
            }
            Text(statusText(group))
                .font(NookTheme.font(10.5, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(statusColor(group.status))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(chipFill(group.status)))
    }

    /// Why a source could not be read, with what fixes it: the permission it misses, or trying again.
    private func failureView(_ reason: String) -> some View {
        let needed = NoticePermission.needed(by: reason)
        return HStack(alignment: .center, spacing: 10) {
            Text(reason)
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let needed, !needed.isGranted(permissions) {
                SourceFixButton(title: tr("chat.notice.allow"), symbol: "lock.open", prominent: true) { needed.grant(app: app) }
                    .help(tr("chat.notice.allowHelp"))
            } else if let onRetry {
                SourceFixButton(title: tr("chat.retry"), symbol: "arrow.clockwise", prominent: false, action: onRetry)
            }
        }
        .padding(.leading, 22)
    }

    /// Older answers stored the raw system error; show those the way new answers do.
    static func readable(_ reason: String) -> String {
        if reason.contains("CancellationError") { return tr("chat.sources.interrupted") }
        if reason.isEmpty || reason.contains("couldn’t be completed") || reason.contains("couldn't be completed") {
            return tr("chat.sources.unknownError")
        }
        return reason
    }

    private func iconSource(_ group: SourceGroup) -> (id: String?, source: ContextSource?) {
        let id = SourceCatalog.all.first { $0.title == group.title }?.id
            ?? app.connectors.sources.first { $0.title == group.title }?.id
        return (id, id.flatMap { app.connectors.source(id: $0) })
    }

    private func plainIcon(_ group: SourceGroup) -> some View {
        let (id, source) = iconSource(group)
        return SiteIcon(domain: source?.iconDomain, fallback: source?.symbol ?? Self.symbol(id), tint: NookTheme.textSecondary,
                        size: 12, source: id)
    }

    /// The source's own icon, with its status as a small dot on the corner.
    private func sourceIcon(_ group: SourceGroup) -> some View {
        let (id, source) = iconSource(group)
        return SiteIcon(domain: source?.iconDomain, fallback: source?.symbol ?? Self.symbol(id), tint: NookTheme.textSecondary,
                        size: 14, source: id)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(color(group.status)).frame(width: 5, height: 5)
                    .overlay(Circle().stroke(NookTheme.ink, lineWidth: 1))
                    .offset(x: 2, y: 2)
            }
    }

    /// A symbol for the sources that are not a connector (screen, web, open items).
    static func symbol(_ id: String?) -> String {
        switch id {
        case SourceCatalog.screen: return "macwindow"
        case SourceCatalog.web: return "globe"
        case SourceCatalog.loops: return "checklist"
        case SourceCatalog.memory: return "brain.head.profile"
        default: return "circle.grid.2x2"
        }
    }

    private func color(_ status: Status) -> Color {
        switch status {
        case .found, .context: return NookTheme.mint
        case .empty: return NookTheme.textTertiary
        case .failed: return NookTheme.coralSoft
        case .running: return NookTheme.iris
        }
    }

    private func chipFill(_ status: Status) -> Color {
        switch status {
        case .found: return NookTheme.mint.opacity(0.1)
        case .failed: return NookTheme.coral.opacity(0.12)
        case .running: return NookTheme.iris.opacity(0.12)
        case .empty, .context: return NookTheme.smoke
        }
    }

    private func statusColor(_ status: Status) -> Color {
        switch status {
        case .found: return NookTheme.mint
        case .failed: return NookTheme.coralSoft
        case .running: return NookTheme.iris
        case .empty, .context: return NookTheme.textTertiary
        }
    }

    /// Every source says how it went: found (and how much), nothing found, sent as context, not read, or still searching.
    private func statusText(_ group: SourceGroup) -> String {
        switch group.status {
        case .found:
            let count = group.references.count
            if count == 0 { return tr("chat.sources.foundShort") }
            return count == 1 ? tr("chat.sources.resultsOne") : tr("chat.sources.results", count)
        case .context: return tr("chat.sources.context")
        case .empty: return tr("chat.sources.nothing").capitalizedFirst
        case .failed: return tr("chat.sources.notRead")
        case .running: return tr("chat.sources.searching")
        }
    }

    /// The exact queries as a tooltip (a failed source shows its reason in the row itself).
    private func helpText(_ group: SourceGroup) -> String {
        var parts: [String] = []
        if !group.queries.isEmpty { parts.append(group.queries.map { "\"\($0)\"" }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The button under a source that could not be read: grant the missing permission, or try again.
private struct SourceFixButton: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(prominent ? NookTheme.ink : NookTheme.paper)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(prominent ? NookTheme.amber : NookTheme.smoke))
        }
        .buttonStyle(.plain)
    }
}

/// A macOS permission a notice says is missing, so the warning can carry the button that grants it.
enum NoticePermission: Hashable {
    case system(SystemPermission)
    case fullDisk
    case automation

    /// Read from the notice text: the errors name the pane in System Settings (in Dutch or English).
    static func needed(by notice: String) -> NoticePermission? {
        let text = notice.lowercased()
        if text.contains("volledige schijftoegang") || text.contains("full disk access") { return .fullDisk }
        if text.contains("› toegankelijkheid") || text.contains("› accessibility") { return .system(.accessibility) }
        if text.contains("schermopname") || text.contains("screen recording") { return .system(.screen) }
        if text.contains("› automatisering") || text.contains("› automation") { return .automation }
        return nil
    }

    @MainActor
    func isGranted(_ monitor: PermissionMonitor) -> Bool {
        if case .system(let permission) = self { return monitor.isGranted(permission) }
        // macOS offers no quiet check for Full Disk Access or Automation: the button stays until the question is asked again.
        return false
    }

    @MainActor
    func grant(app: AppModel) {
        switch self {
        case .system(let permission):
            Task { await PermissionMonitor.shared.request(permission, app: app) }
        case .fullDisk, .automation:
            let anchor = self == .fullDisk ? "Privacy_AllFiles" : "Privacy_Automation"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                PermissionMonitor.shared.openedSettings = Date()
                NSWorkspace.shared.open(url)
            }
        }
    }
}

extension ChatMessage {
    /// The warnings to show under the answer. Older answers also repeated every unreadable source as a warning
    /// ("Mail could not be searched: …", "This answer may therefore be incomplete."); the sources card shows those now.
    var visibleNotices: [String] {
        let failures = retrieval.compactMap { step -> String? in
            if case .failed(let error) = step.outcome, !error.isEmpty { return error }
            return nil
        }
        guard !failures.isEmpty else { return notices }
        return notices.filter { notice in
            !Self.legacyIncomplete.contains(notice) && !failures.contains { notice.contains($0) }
        }
    }

    private static let legacyIncomplete: Set<String> = [
        "Dit antwoord is daardoor mogelijk onvolledig.",
        "This answer may therefore be incomplete.",
        "Diese Antwort ist daher möglicherweise unvollständig.",
        "Cette réponse peut donc être incomplète.",
        "Por eso esta respuesta puede estar incompleta.",
    ]
}

/// Warnings for an answer, such as a source that could not be read. A warning about a missing permission gets the button
/// that grants it, so it can be fixed right from the chat.
struct NoticeList: View {
    let notices: [String]
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var permissions = PermissionMonitor.shared

    /// The permission each notice asks for; only the first notice per permission shows the button.
    private var buttons: [String: NoticePermission] {
        var seen: Set<NoticePermission> = []
        var result: [String: NoticePermission] = [:]
        for notice in notices {
            guard let needed = NoticePermission.needed(by: notice), !seen.contains(needed) else { continue }
            seen.insert(needed)
            if !needed.isGranted(permissions) { result[notice] = needed }
        }
        return result
    }

    var body: some View {
        let buttons = buttons
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notices, id: \.self) { notice in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(NookTheme.amber)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notice)
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let needed = buttons[notice] {
                            SourceFixButton(title: tr("chat.notice.allow"), symbol: "lock.open", prominent: true) { needed.grant(app: app) }
                                .help(tr("chat.notice.allowHelp"))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(NookTheme.amber.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(NookTheme.amber.opacity(0.18), lineWidth: 1))
        )
    }
}

private struct ReferenceRow: View {
    let reference: SourceReference
    let cited: Bool
    let open: () -> Void
    @State private var hovering = false

    private var openable: Bool { SourceReference.isOpenable(reference.url) }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(reference.number)")
                    .font(NookTheme.font(10, .bold))
                    .foregroundStyle(cited ? NookTheme.ink : NookTheme.textSecondary)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(cited ? NookTheme.iris : NookTheme.smoke))
                VStack(alignment: .leading, spacing: 1) {
                    Text(reference.title)
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(([SourceCatalog.title(reference.sourceID)] + (reference.detail.isEmpty ? [] : [reference.detail])).joined(separator: " · "))
                        .font(NookTheme.font(11))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if openable {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textTertiary)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering && openable ? NookTheme.smoke : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!openable)
        .onHover { hovering = $0 }
        .help(openable ? tr("chat.references.open") : tr("chat.references.noLink"))
    }
}

// MARK: Input: source picker, context, and attachment

/// Which sources this Nook is allowed to use. Automatic = Nook selects autonomously from all connected sources.
struct ScopeMenu: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel

    private var scope: SourceScope { app.scope(of: chat.activeID) }

    private func update(_ change: (inout SourceScope) -> Void) {
        var next = app.scope(of: chat.activeID)
        change(&next)
        if next.mode == .only && next.included.isEmpty { next.mode = .automatic }
        app.setScope(next)
    }

    private func onlyBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { scope.mode == .only && scope.included.contains(id) },
            set: { on in
                update { scope in
                    if on {
                        if scope.mode != .only { scope.included = [] }
                        scope.mode = .only
                        scope.included.insert(id)
                        scope.excluded.remove(id)
                    } else {
                        scope.included.remove(id)
                    }
                }
            }
        )
    }

    private func neverBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { scope.excluded.contains(id) },
            set: { on in
                update { scope in
                    if on { scope.excluded.insert(id); scope.included.remove(id) } else { scope.excluded.remove(id) }
                }
            }
        )
    }

    /// Services with more than one connected account: only there choosing accounts matters.
    private var accountServices: [String] {
        let _ = app.connectors.revision
        guard let github = app.connectors.source(id: "github") as? GitHubConnector, github.isActive, github.accounts.count > 1 else { return [] }
        return ["github"]
    }

    private func accountBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { scope.allowsAccount(id) },
            set: { on in
                update { scope in
                    var excluded = scope.excludedAccounts ?? []
                    if on { excluded.remove(id) } else { excluded.insert(id) }
                    scope.excludedAccounts = excluded.isEmpty ? nil : excluded
                }
            }
        )
    }

    var body: some View {
        let current = scope
        Menu {
            Button { app.setScope(.automatic) } label: {
                Label(current == .automatic ? "✓ " + tr("scope.automatic") : tr("scope.automatic"), systemImage: "sparkles")
            }
            Section(tr("scope.onlyThese")) {
                ForEach(app.connectors.active.map { $0.id }, id: \.self) { id in
                    Toggle(isOn: onlyBinding(id)) { sourceLabel(id) }
                }
                Toggle(isOn: onlyBinding(SourceCatalog.web)) { sourceLabel(SourceCatalog.web) }
            }
            let multi = accountServices
            if !multi.isEmpty {
                Section(tr("scope.accounts")) {
                    ForEach(multi, id: \.self) { service in
                        ForEach(AccountRegistry.shared.accounts(for: service)) { account in
                            Toggle(isOn: accountBinding(account.id)) {
                                sourceLabel(service, title: account.title(service: SourceCatalog.title(service)))
                            }
                        }
                    }
                }
            }
            Section(tr("scope.never")) {
                Toggle(isOn: neverBinding(SourceCatalog.screen)) { sourceLabel(SourceCatalog.screen) }
                Toggle(isOn: neverBinding(SourceCatalog.web)) { sourceLabel(SourceCatalog.web) }
                Toggle(isOn: neverBinding("clipboard")) { sourceLabel("clipboard") }
            }
        } label: {
            ComposerPill(symbol: "line.3.horizontal.decrease",
                         text: current.isRestricted ? current.label() : tr("scope.automaticShort"),
                         tint: current.isRestricted ? NookTheme.iris : nil)
        }
        .composerMenu()
        .help(tr("scope.help"))
    }

    /// A source in the menu with its real icon: the app or the service's logo, else its own symbol (screen, web…).
    private func sourceLabel(_ id: String, title: String? = nil) -> some View {
        let source = app.connectors.source(id: id)
        let text = title ?? source?.title ?? SourceCatalog.title(id)
        let image = SourceBrand.menuImage(for: id, domain: source?.iconDomain)
            ?? NSImage(systemSymbolName: source?.symbol ?? SourcesDisclosure.symbol(id), accessibilityDescription: nil)
        return Label {
            Text(text)
        } icon: {
            if let image { Image(nsImage: image) }
        }
    }
}

/// The plus menu in the chat input: everything you add to a question or want to check, in one place.
struct ComposerMoreMenu: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel
    @State private var showContext = false

    var body: some View {
        ComposerPlusMenu(attach: { app.attachFile() }) {
            Button { app.captureScreenPart() } label: { Label(tr("chat.capture.menu"), systemImage: "camera.viewfinder") }
            Button { NoteTaker.shared.toggle() } label: {
                Label(NoteTaker.shared.isRecording ? tr("notes.menu.stop") : tr("notes.menu.start"), systemImage: "waveform.badge.mic")
            }
            Divider()
            Button { showContext = true } label: { Label(tr("chat.contextShort"), systemImage: "eye") }
        }
        .popover(isPresented: $showContext, arrowEdge: .top) { ContextInspector(chat: chat) }
    }
}

/// What context is sent with a query to the brain, and destination. Keeps Nook's data usage transparent.
struct ContextInspector: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel

    var body: some View { content }

    private var destination: String {
        let settings = app.settings
        if settings.useLocal { return tr("context.brainLocal") }
        if settings.provider.isLocalServer { return tr("context.brainLocalServer", settings.provider.title) }
        return tr("context.brainCloud", settings.provider.title, settings.provider.title)
    }

    private var content: some View {
        let scope = app.scope(of: chat.activeID)
        let _ = app.connectors.revision
        return VStack(alignment: .leading, spacing: 10) {
            Text(tr("context.title")).font(.headline)
            Text(destination).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(tr("context.how")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            row(SourceCatalog.title(SourceCatalog.screen), screenState(scope), ok: scope.allows(SourceCatalog.screen) && app.settings.liveScreen)
            if let name = app.attachmentName {
                row(tr("context.attachment"), name, ok: true)
            }
            ForEach(app.connectors.sources.map { $0.id }, id: \.self) { id in
                if let source = app.connectors.source(id: id) {
                    row(source.title, sourceState(source, scope: scope), ok: source.isActive && scope.allows(source.id), source: source)
                }
            }
            Divider()
            HStack {
                Text(tr("context.scope", scope.label())).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("context.manage")) { app.openSettings(section: .connections) }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    private func screenState(_ scope: SourceScope) -> String {
        if !scope.allows(SourceCatalog.screen) { return tr("context.offForNook") }
        if !app.screenContext.hasPermission { return tr("context.noPermission") }
        return app.settings.screenWithEveryQuestion ? tr("context.screenEvery") : tr("context.screenOnReference")
    }

    private func sourceState(_ source: ContextSource, scope: SourceScope) -> String {
        guard source.isActive else { return tr("context.notConnected") }
        guard scope.allows(source.id) else { return tr("context.offForNook") }
        var parts: [String] = []
        if case .error(let message) = source.status.state { parts.append(message) } else if !source.status.headline.isEmpty { parts.append(source.status.headline) }
        if let updated = source.status.updated { parts.append(tr("context.updated", NookDates.ago(updated))) }
        return parts.isEmpty ? tr("context.connected") : parts.joined(separator: " · ")
    }

    private func row(_ title: String, _ detail: String, ok: Bool, source: ContextSource? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(ok ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            if let source {
                SiteIcon(domain: source.iconDomain, fallback: source.symbol, tint: source.accent, size: 14, source: source.id)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            }
            Text(title).font(.callout).frame(width: 110, alignment: .leading)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// The file attached to your next query, with a dismiss button to remove it.
struct AttachmentChip: View {
    let name: String
    var isImage = false
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isImage ? "photo" : "paperclip").font(.system(size: 10, weight: .semibold)).foregroundStyle(NookTheme.iris)
            Text(name).font(NookTheme.font(11.5, .medium)).foregroundStyle(NookTheme.paper).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(NookTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("button.clear"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(NookTheme.smoke))
    }
}
