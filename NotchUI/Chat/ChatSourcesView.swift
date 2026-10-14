import SwiftUI
import AppKit

// What Nook used for an answer: where it looked (and whether that succeeded), which sources the answer cites,
// and what you need to know if something could not be read. Plus the source picker and summary of included context.

/// The strip above an answer: which sources were allowed, what context was included, and where Nook looked, with outcomes.
struct RetrievalStrip: View {
    let message: ChatMessage
    @State private var showDetails = false

    private struct Chip: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let color: Color
        let help: String
    }

    private var chips: [Chip] {
        var result: [Chip] = []
        if !message.scopeLabel.isEmpty {
            result.append(Chip(id: "scope", label: message.scopeLabel, symbol: "line.3.horizontal.decrease", color: NookTheme.iris,
                               help: tr("chat.sources.scopeHelp")))
        }
        for source in message.sources {
            result.append(Chip(id: "ctx-" + source, label: source, symbol: "eye", color: NookTheme.textTertiary, help: tr("chat.sources.contextHelp")))
        }
        // One chip per source, even if Nook inspected it multiple times.
        var order: [String] = []
        var grouped: [String: [RetrievalStep]] = [:]
        for step in message.retrieval {
            if grouped[step.sourceTitle] == nil { order.append(step.sourceTitle) }
            grouped[step.sourceTitle, default: []].append(step)
        }
        for title in order {
            let steps = grouped[title] ?? []
            let refs = steps.reduce(0) { $0 + $1.references.count }
            let queries = steps.map(\.query).filter { !$0.isEmpty }
            let queryHelp = queries.isEmpty ? "" : " · " + queries.map { "\"\($0)\"" }.joined(separator: ", ")
            if steps.contains(where: { $0.outcome == .running }) {
                result.append(Chip(id: title, label: title, symbol: "magnifyingglass", color: NookTheme.iris, help: tr("chat.sources.searching") + queryHelp))
            } else if let failed = steps.compactMap({ step -> String? in if case .failed(let error) = step.outcome { return error }; return nil }).first,
                      !steps.contains(where: { if case .found = $0.outcome { return true }; return false }) {
                result.append(Chip(id: title, label: title, symbol: "xmark", color: NookTheme.coralSoft, help: failed))
            } else if steps.allSatisfy({ $0.outcome == .empty }) {
                result.append(Chip(id: title, label: title + " · " + tr("chat.sources.nothing"), symbol: "circle", color: NookTheme.textTertiary,
                                   help: tr("chat.sources.emptyHelp") + queryHelp))
            } else {
                let cached = steps.allSatisfy(\.cached)
                result.append(Chip(id: title, label: refs > 0 ? "\(title) · \(refs)" : title, symbol: "checkmark", color: NookTheme.mint,
                                   help: (cached ? tr("chat.sources.cached") : tr("chat.sources.searched")) + queryHelp))
            }
        }
        return result
    }

    var body: some View {
        let list = chips
        if !list.isEmpty || !message.contextSources.isEmpty {
            HStack(spacing: 5) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(list) { chip in
                            HStack(spacing: 4) {
                                Image(systemName: chip.symbol)
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(chip.color)
                                Text(chip.label)
                                    .font(NookTheme.font(10.5, .medium))
                                    .foregroundStyle(NookTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NookTheme.graphite))
                            .help(chip.help)
                        }
                    }
                }
                Button { showDetails.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(tr("chat.sources.detailsHelp"))
                .popover(isPresented: $showDetails, arrowEdge: .bottom) { details }
            }
        }
    }

    /// Exact breakdown of events: included context and each retrieval step with query and outcome.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("chat.sources.detailsTitle")).font(.headline)
            if !message.scopeLabel.isEmpty {
                Text(tr("chat.sources.scope", message.scopeLabel)).font(.callout)
            }
            if !message.contextSources.isEmpty || !message.sources.isEmpty {
                Text(tr("chat.sources.sentAsContext", (message.sources + message.contextSources).joined(separator: ", ")))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.retrieval.isEmpty {
                Text(tr("chat.sources.noTools")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(message.retrieval) { step in
                HStack(alignment: .top, spacing: 6) {
                    Text(step.sourceTitle).font(.callout.weight(.semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.tool + (step.query.isEmpty ? "" : " · \"\(step.query)\"")).font(.caption.monospaced())
                        Text(outcomeText(step)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func outcomeText(_ step: RetrievalStep) -> String {
        let suffix = step.cached ? " · " + tr("chat.sources.cached") : ""
        switch step.outcome {
        case .running: return tr("chat.sources.searching")
        case .found(let count): return tr("chat.sources.found", count) + (step.references.isEmpty ? "" : " · " + step.references.map { "[\($0)]" }.joined(separator: " ")) + suffix
        case .empty: return tr("chat.sources.nothing") + suffix
        case .failed(let error): return tr("chat.sources.failed", error)
        }
    }
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

/// The sources backing the answer, numbered as cited in the text. Clicking opens the original.
struct ReferenceList: View {
    let references: [SourceReference]
    let cited: Set<Int>
    @EnvironmentObject private var app: AppModel
    @State private var showAll = false

    var body: some View {
        let visible = showAll ? references : Array(references.prefix(4))
        VStack(alignment: .leading, spacing: 3) {
            Text(tr("chat.references.title"))
                .font(NookTheme.font(10.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            ForEach(visible) { reference in
                ReferenceRow(reference: reference, cited: cited.contains(reference.number)) { app.openReference(reference) }
            }
            if references.count > visible.count {
                Button(tr("chat.references.more", references.count - visible.count)) { showAll = true }
                    .buttonStyle(.plain)
                    .font(NookTheme.font(11.5, .medium))
                    .foregroundStyle(NookTheme.iris)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NookTheme.line2, lineWidth: 1))
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

    var body: some View {
        let current = scope
        Menu {
            Button(current == .automatic ? "✓ " + tr("scope.automatic") : tr("scope.automatic")) { app.setScope(.automatic) }
            Section(tr("scope.onlyThese")) {
                ForEach(app.connectors.active.map { $0.id }, id: \.self) { id in
                    Toggle(app.connectors.source(id: id)?.title ?? SourceCatalog.title(id), isOn: onlyBinding(id))
                }
                Toggle(SourceCatalog.title(SourceCatalog.web), isOn: onlyBinding(SourceCatalog.web))
            }
            Section(tr("scope.never")) {
                Toggle(SourceCatalog.title(SourceCatalog.screen), isOn: neverBinding(SourceCatalog.screen))
                Toggle(SourceCatalog.title(SourceCatalog.web), isOn: neverBinding(SourceCatalog.web))
                Toggle(SourceCatalog.title("clipboard"), isOn: neverBinding("clipboard"))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: current.isRestricted ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(current.isRestricted ? current.label() : tr("scope.automaticShort"))
                    .font(NookTheme.font(11.5, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(current.isRestricted ? NookTheme.iris : NookTheme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("scope.help"))
    }
}

/// What context is sent with a query to the brain, and destination. Keeps Nook's data usage transparent.
struct ContextInspector: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel
    @State private var shown = false

    var body: some View {
        NookIconButton(systemName: "eye", label: tr("context.title"), size: 26) { shown.toggle() }
            .help(tr("context.title"))
            .popover(isPresented: $shown, arrowEdge: .top) { content }
    }

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
                    row(source.title, sourceState(source, scope: scope), ok: source.isActive && scope.allows(source.id))
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
        if let updated = source.status.updated { parts.append(tr("context.updated", NookDates.relative(updated))) }
        return parts.isEmpty ? tr("context.connected") : parts.joined(separator: " · ")
    }

    private func row(_ title: String, _ detail: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(ok ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
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
