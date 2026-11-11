import SwiftUI
import AppKit

/// Settings › Sessions › Tokens: Nook's own savings, and what in each coding agent's setup goes with every request
/// unused, with the setting that turns it off (`AgentTuning`).
@MainActor
final class AgentTuningModel: ObservableObject {
    @Published private(set) var advice: [TuningAdvice] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var applied = AgentTuning.Applied.load()

    /// Reads the agents' files again, off the main thread (Claude Code's transcripts can be large).
    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .utility) { AgentTuning.scan() }.value
            advice = found
            scanning = false
            scanned = true
        }
    }

    func isApplied(_ item: TuningAdvice) -> Bool { applied.isApplied(item) }

    /// The suggestions, plus what you applied earlier and no scan suggests now (a plugin you used since): it stays
    /// listed, so it can be turned off again.
    var rows: [TuningAdvice] {
        AgentTuning.withApplied(advice, applied: applied,
                                settingsFile: FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".claude/settings.json").path)
    }

    func setApplied(_ item: TuningAdvice, _ on: Bool) {
        applied.set(item, on: on)
        applied.save()
    }
}

struct TokenSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var ws = WorkspaceSettings.shared
    @StateObject private var model = AgentTuningModel()

    var body: some View {
        Section {
            Toggle(tr("settings.ws.idleCompaction"), isOn: $ws.idleCompaction)
                .help(tr("settings.ws.idleCompaction.help"))
                .onChange(of: ws.idleCompaction) { _, _ in app.workspace.idleCompactionSettingChanged() }
            Picker(tr("settings.ws.autoCompact"), selection: $ws.autoCompactTokens) {
                ForEach(SizeCompaction.choices, id: \.self) { tokens in
                    Text(tokens == 0 ? tr("settings.ws.autoCompact.off") : "\(tokens / 1000)K tokens").tag(tokens)
                }
            }
            .help(tr("settings.ws.autoCompact.help"))
            SettingNote(tr("tuning.nookDoes"))
        } header: {
            SettingsSectionTitle(tr("tuning.nook.title"))
        }
        Section {
            if model.scanning && !model.scanned {
                SettingNote(tr("tuning.checking"))
            } else if model.rows.isEmpty {
                SettingNote(tr("tuning.none"))
            }
            ForEach(model.rows) { item in
                TuningAdviceRow(item: item, applied: Binding(get: { model.isApplied(item) }, set: { on in
                    model.setApplied(item, on)
                    app.store.audit(tool: "token_tuning", args: "\(item.provider.displayName) · \(item.kind.rawValue) · "
                                    + item.items.joined(separator: ", "), result: on ? "applied in Nook sessions" : "removed")
                }))
            }
            SettingNote(tr("tuning.limits"))
            HStack {
                Spacer()
                SmallGhostButton(title: tr(model.scanning ? "tuning.checking" : "tuning.recheck")) { model.scan() }
                    .disabled(model.scanning)
            }
        } header: {
            SettingsSectionTitle(tr("tuning.agents.title"), info: tr("tuning.agents.info"))
        }
        .onAppear { if !model.scanned { model.scan() } }
    }
}

/// One suggestion: the agent and what it is about, what it costs, and how to turn it off.
private struct TuningAdviceRow: View {
    let item: TuningAdvice
    @Binding var applied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            AgentName(item.provider.kind, name: item.provider.displayName + " · " + tr("tuning.kind.\(item.kind.rawValue)"))
                .font(NookTheme.TextStyle.strong)
            Text(detail)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = item.snippet {
                Text(snippet)
                    .font(NookTheme.TextStyle.code)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(NookTheme.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.chip)
            }
            HStack(spacing: NookTheme.Spacing.md) {
                if item.appliesInNook {
                    Toggle(tr("tuning.inNook"), isOn: $applied)
                        .help(tr("tuning.inNook.help"))
                }
                Spacer()
                if let snippet = item.snippet { CopyGhostButton { snippet } }
                SmallGhostButton(title: tr(isPage ? "tuning.openPage" : "tuning.showFile")) { open() }
            }
        }
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    private var isPage: Bool { item.location.hasPrefix("https://") }

    private var detail: String {
        var lines: [String] = []
        if !item.items.isEmpty, item.kind != .longInstructions { lines.append(item.items.joined(separator: ", ")) }
        if let tokens = item.tokens { lines.append(tr("tuning.tokens", tokens)) }
        if !item.kept.isEmpty { lines.append(tr("tuning.kept", item.kept.joined(separator: ", "))) }
        lines.append(tr("tuning.why.\(item.kind.rawValue)"))
        lines.append(tr("tuning.where", AgentPathFormat.tilde(item.location)))
        return lines.joined(separator: "\n")
    }

    private func open() {
        if isPage, let url = URL(string: item.location) {
            NSWorkspace.shared.open(url)
        } else {
            let url = URL(fileURLWithPath: item.location)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
