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
                result[i].status = .running
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

    var body: some View {
        let list = groups
        if !list.isEmpty {
            let used = list.filter { if case .found = $0.status { return true }; if case .context = $0.status { return true }; return false }.count
            let failed = failedCount
            let running = list.contains { if case .running = $0.status { return true }; return false }
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(summary(used: used, failed: failed, running: running))
                            .font(NookTheme.font(12, .medium))
                            .foregroundStyle(failed > 0 ? NookTheme.amber : NookTheme.textSecondary)
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
                .accessibilityLabel(summary(used: used, failed: failed, running: running))

                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { group in groupView(group) }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
                    .transition(.opacity)
                }
            }
            .onAppear { if failed > 0 { expanded = true } }
            .onChange(of: failedCount) { _, count in if count > 0 { expanded = true } }
        }
    }

    private func summary(used: Int, failed: Int, running: Bool) -> String {
        if running && message.streaming { return tr("chat.sources.searchingShort") }
        var text = used == 1 ? tr("chat.sources.usedOne") : tr("chat.sources.used", used)
        if used == 0 && failed == 0 { text = tr("chat.sources.nothing").capitalizedFirst }
        if failed > 0 { text += tr("chat.sources.unread", failed) }
        return text
    }

    private func groupView(_ group: SourceGroup) -> some View {
        let cited = Citations.used(in: message.text)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                sourceIcon(group)
                Text(group.title)
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                Spacer(minLength: 6)
                Text(statusText(group.status))
                    .font(NookTheme.font(11))
                    .foregroundStyle(failedColor(group.status))
                    .lineLimit(1)
                if case .failed = group.status, let onRetry {
                    Button(action: onRetry) {
                        Text(tr("chat.retry"))
                            .font(NookTheme.font(11, .semibold))
                            .foregroundStyle(NookTheme.paper)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NookTheme.smoke))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .help(helpText(group))
            if !message.streaming {
                ForEach(group.references) { reference in
                    ReferenceRow(reference: reference, cited: cited.contains(reference.number)) { app.openReference(reference) }
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// The source's own icon, with its status as a small dot on the corner.
    private func sourceIcon(_ group: SourceGroup) -> some View {
        let id = SourceCatalog.all.first { $0.title == group.title }?.id
            ?? app.connectors.sources.first { $0.title == group.title }?.id
        let source = id.flatMap { app.connectors.source(id: $0) }
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

    private func failedColor(_ status: Status) -> Color {
        if case .failed = status { return NookTheme.coralSoft }
        return NookTheme.textTertiary
    }

    private func statusText(_ status: Status) -> String {
        switch status {
        case .found: return ""
        case .context: return tr("chat.sources.context")
        case .empty: return tr("chat.sources.nothing")
        case .failed: return tr("chat.sources.notRead")
        case .running: return tr("chat.sources.searching")
        }
    }

    /// The exact queries and, for a failed source, the error as a tooltip.
    private func helpText(_ group: SourceGroup) -> String {
        var parts: [String] = []
        if case .failed(let error) = group.status { parts.append(error) }
        if !group.queries.isEmpty { parts.append(group.queries.map { "\"\($0)\"" }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Warnings for an answer, such as a source that could not be read.
struct NoticeList: View {
    let notices: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notices, id: \.self) { notice in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(NookTheme.amber)
                        .padding(.top, 2)
                    Text(notice)
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
        Menu {
            Button { app.attachFile() } label: { Label(tr("chat.attachShort"), systemImage: "paperclip") }
            Divider()
            Button { showContext = true } label: { Label(tr("chat.contextShort"), systemImage: "eye") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(NookTheme.smoke))
                .contentShape(Circle())
        }
        .composerMenu()
        .help(tr("chat.more"))
        .accessibilityLabel(tr("chat.more"))
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
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "paperclip").font(.system(size: 10, weight: .semibold)).foregroundStyle(NookTheme.iris)
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
