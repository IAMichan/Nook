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
                .onChange(of: query) { _, _ in load() }
            if entries.isEmpty {
                Text(tr("privacy.log.empty")).foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(entries.prefix(100)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.tool).font(NookTheme.font(13, .medium))
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
                if !note.isEmpty { Text(note).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary) }
                ConfirmedButton(tr("privacy.log.clear"), question: tr("confirm.clearAudit"), detail: tr("confirm.clearAudit.detail")) {
                    app.store.clearAudit()
                    note = tr("privacy.log.cleared")
                    load()
                }
                .disabled(entries.isEmpty)
            }
        } header: {
            Text(tr("privacy.log.title"))
        } footer: {
            Text(tr("privacy.log.footer"))
        }
        .onAppear(perform: load)
    }

    private func load() {
        entries = app.store.auditEntries(limit: 200, matching: query)
    }
}
