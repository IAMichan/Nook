import SwiftUI

/// Settings › Privacy: which sources only a brain on this Mac may read.
extension SettingsView {
    // MARK: Only on this Mac

    /// A tab of its own: what is kept on this Mac and the two quick choices first, then a switch per source, which grows
    /// with every service you link, so it can be searched.
    @ViewBuilder
    var privateSourcesSection: some View {
        Section {
            SettingNote(settings.isLocalBrain
                        ? tr("settings.private.activeLocal")
                        : tr("settings.private.activeExternal", settings.privateSources.count))
            HStack {
                Button(tr("settings.private.all")) { settings.localOnlySources = SourceCatalog.personal }
                Button(tr("settings.private.none")) { settings.localOnlySources = [] }
                    .disabled(settings.localOnlySources.isEmpty)
                Spacer()
            }
        } header: {
            SettingsSectionTitle(tr("settings.private.title"), info: tr("settings.private.footer"))
        }
        Section {
            NookSearchField(prompt: tr("settings.private.search"), text: $sourceQuery, style: .inline)
            let text = sourceQuery.trimmingCharacters(in: .whitespaces)
            let shown = SourceCatalog.all.filter { text.isEmpty || Self.sourceName($0).localizedCaseInsensitiveContains(text) }
            ForEach(shown, id: \.id) { source in
                // The privacy level can keep a source on this Mac by itself (the screen when strict): shown locked.
                let byLevel = settings.privacyLevel.localOnlySources.contains(source.id)
                Toggle(isOn: byLevel ? .constant(true) : localOnlyBinding(source.id)) {
                    Label(Self.sourceName(source), systemImage: byLevel || settings.localOnlySources.contains(source.id) ? "lock.fill" : "lock.open")
                }
                .disabled(byLevel)
                .help(byLevel ? tr("settings.private.byLevel") : "")
            }
            if shown.isEmpty { SettingNote(tr("settings.search.none")) }
        } header: {
            Text(tr("settings.private.choose", settings.localOnlySources.count, SourceCatalog.all.count))
        }
    }

    /// A source by its name in the app's language: the catalogue's own titles are the words Nook matches questions on
    /// (Dutch for the Mac's own sources), not what Settings should show.
    static func sourceName(_ source: SourceDescriptor) -> String {
        let key = "source.name.\(source.id)"
        let name = tr(key)
        return name == key ? source.title : name
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
