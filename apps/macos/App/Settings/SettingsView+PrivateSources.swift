import SwiftUI

/// Settings › Privacy: which sources only a brain on this Mac may read.
extension SettingsView {
    // MARK: Only on this Mac

    var privateSourcesSection: some View {
        Section {
            ForEach(SourceCatalog.all, id: \.id) { source in
                // The privacy level can keep a source on this Mac by itself (the screen when strict): shown locked.
                let byLevel = settings.privacyLevel.localOnlySources.contains(source.id)
                Toggle(isOn: byLevel ? .constant(true) : localOnlyBinding(source.id)) {
                    Label(source.title, systemImage: byLevel || settings.localOnlySources.contains(source.id) ? "lock.fill" : "lock.open")
                }
                .disabled(byLevel)
                .help(byLevel ? tr("settings.private.byLevel") : "")
            }
            HStack {
                Button(tr("settings.private.all")) { settings.localOnlySources = SourceCatalog.personal }
                Button(tr("settings.private.none")) { settings.localOnlySources = [] }
                    .disabled(settings.localOnlySources.isEmpty)
                Spacer()
            }
            Text(settings.isLocalBrain
                 ? tr("settings.private.activeLocal")
                 : tr("settings.private.activeExternal", settings.privateSources.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(tr("settings.private.title"))
        } footer: {
            Text(tr("settings.private.footer"))
        }
    }

    private func localOnlyBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.localOnlySources.contains(id) },
            set: { on in
                if on { settings.localOnlySources.insert(id) } else { settings.localOnlySources.remove(id) }
            }
        )
    }
}
