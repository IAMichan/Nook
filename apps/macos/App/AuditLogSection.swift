import SwiftUI

/// Settings › Privacy: the action log. What Nook carried out for you, when, and with what result.
struct AuditLogSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var entries: [AuditEntry] = []
    @State private var note = ""

    var body: some View {
        Section {
            TextField(tr("privacy.log.search"), text: $query)
                .onSubmit(load)
                // Once you pause typing: the search reads up to 90 days of the log, and ran with every key.
                .task(id: query) {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !Task.isCancelled { load() }
                }
            if entries.isEmpty {
                Text(tr("privacy.log.empty")).foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(entries.prefix(100)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.tool).font(NookTheme.TextStyle.strong)
                        Spacer()
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                    }
                    if !entry.result.isEmpty {
                        Text(entry.result).font(NookTheme.TextStyle.detail)
                            .foregroundStyle(entry.result.hasPrefix("FOUT") ? NookTheme.coral : NookTheme.textSecondary)
                            .lineLimit(2)
                    }
                    if !entry.args.isEmpty, entry.args != "{}" {
                        Text(entry.args).font(NookTheme.mono(10.5)).foregroundStyle(NookTheme.textTertiary).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                if !note.isEmpty { SettingNote(note) }
                ConfirmedButton(tr("privacy.log.clear"), question: tr("confirm.clearAudit"), detail: tr("confirm.clearAudit.detail")) {
                    app.store.clearAudit()
                    note = tr("privacy.log.cleared")
                    load()
                }
                .disabled(entries.isEmpty)
            }
        } header: {
            SettingsSectionTitle(tr("privacy.log.title"), info: tr("privacy.log.footer"))
        }
        .onAppear(perform: load)
    }

    private func load() {
        entries = app.store.auditEntries(limit: 200, matching: query)
    }
}
