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
                Text(tr("privacy.log.empty")).foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(100)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.tool).font(.callout.weight(.medium))
                        Spacer()
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !entry.result.isEmpty {
                        Text(entry.result).font(.caption)
                            .foregroundStyle(entry.result.hasPrefix("FOUT") ? Color.red : Color.secondary)
                            .lineLimit(2)
                    }
                    if !entry.args.isEmpty, entry.args != "{}" {
                        Text(entry.args).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                Button(tr("privacy.log.clear"), role: .destructive) {
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
