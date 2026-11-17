import SwiftUI

/// Settings › Coding agents › Skills: skills from the internet for every coding agent. Where they go (you, or one
/// project, and for which agents), the ones Nook installed with their updates, and finding new ones through skills.sh or
/// a GitHub repository. Nothing is installed without its preview: the SKILL.md, its files and every script, and the
/// commit it is pinned to.
struct SkillsSettingsSection: View {
    @ObservedObject private var store = SkillsStore.shared
    @ObservedObject private var ws = WorkspaceSettings.shared
    /// "" for yourself, else a project folder.
    @State private var scopePath = ""
    @State private var query = ""
    @State private var sheet: SkillSheetRoute?
    @State private var addingSource = false

    private var scope: SkillScope {
        scopePath.isEmpty ? .user : .project(URL(fileURLWithPath: scopePath, isDirectory: true))
    }

    var body: some View {
        whereSection
        installedSection
        findSection
        collectionsSection
            .sheet(item: $sheet) { route in
                SkillSheet(route: route, scope: scope, providers: chosenProviders)
            }
            .sheet(isPresented: $addingSource) {
                SkillSourceSheet { ws.skillSources.append($0) }
            }
            .onAppear { refresh(checking: true) }
            .onChange(of: scopePath) { _, _ in refresh(checking: true) }
    }

    private var chosenProviders: [RunProvider] { SkillsStore.supported.filter { store.providers.contains($0) } }

    private func refresh(checking: Bool) {
        store.reload(scope)
        if checking {
            // After the list is read: the check needs to know what is installed.
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                store.checkUpdates(scope)
            }
        }
    }

    // MARK: Where

    private var whereSection: some View {
        let projects = ProjectSettings.scopeChoices(favorites: ws.favoriteProjects, recent: ws.recentProjects, overrides: ws.projectOverrides)
        return Section {
            Picker(selection: $scopePath) {
                Text(tr("skills.where.user")).tag("")
                if !projects.isEmpty {
                    Divider()
                    ForEach(projects, id: \.self) { path in
                        Text(ws.projectDisplayName(path)).tag(path).help(AgentPathFormat.tilde(path)) // menu item
                    }
                }
            } label: {
                SettingLabel(tr("skills.where.for"), hint: scopePath.isEmpty ? tr("skills.where.userHint") : tr("skills.where.projectHint"))
            }
            LabeledContent {
                Menu {
                    ForEach(SkillsStore.supported) { provider in
                        Toggle(isOn: Binding(get: { store.providers.contains(provider) }, set: { on in
                            if on { store.providers.insert(provider) } else if store.providers.count > 1 { store.providers.remove(provider) }
                        })) {
                            Text(provider.displayName)
                        }
                    }
                } label: {
                    Text(agentSummary)
                }
                .nookMenuButton()
            } label: {
                SettingLabel(tr("skills.where.agents"), hint: tr("skills.where.agentsHint"))
            }
        } header: {
            SettingsSectionTitle(tr("skills.where.title"), info: tr("skills.where.info"))
        }
    }

    private var agentSummary: String {
        let names = chosenProviders.map(\.displayName)
        return names.count == SkillsStore.supported.count ? tr("skills.where.allAgents") : names.joined(separator: ", ")
    }

    // MARK: Installed

    private var installedSection: some View {
        Section {
            if store.installed.isEmpty {
                ConnectionListEmpty(title: tr("skills.installed.empty"), detail: tr("skills.installed.emptyDetail"))
            }
            ForEach(store.installed) { entry in
                installedRow(entry)
            }
            if store.checking {
                BusyLine(tr("skills.updates.checking"), tone: .tertiary, font: NookTheme.TextStyle.detail)
            } else if let error = store.checkError {
                SettingNote(error, tone: .warning)
            }
        } header: {
            ConnectionListHeader(title: tr("skills.installed.title"), info: tr("skills.installed.info"),
                                 add: store.installed.isEmpty ? nil : (tr("skills.updates.check"), { store.checkUpdates(scope, force: true) }),
                                 symbol: "arrow.clockwise")
        }
    }

    private func installedRow(_ entry: SkillLibraryEntry) -> some View {
        let update = store.updates[entry.id]
        let agents = entry.providers.map(\.displayName).joined(separator: ", ")
        return ConnectionRow(title: entry.name, version: String(entry.commit.prefix(7)),
                             status: update == nil ? .connected : .expired,
                             statusText: update == nil ? tr("skills.installed.from", entry.repository) : tr("skills.updates.available"),
                             detail: agents,
                             removal: ConnectionRemoval(title: tr("skills.remove"), question: tr("confirm.remove", entry.name),
                                                        detail: tr("skills.remove.detail", agents)) { store.remove(entry) }) {
            Image(icon: "book.closed")
                .font(NookTheme.font(15, .medium))
                .foregroundStyle(NookTheme.textSecondary)
        } menu: {
            if let update {
                Button(tr("skills.update")) { sheet = .update(entry, update) }
            }
            if let url = URL(string: "https://github.com/\(entry.repository)/tree/\(entry.commit)/\(entry.places[0].provenance.folder)") {
                Button(tr("skills.openOnGitHub")) { NSWorkspace.shared.open(url) }
            }
        } expanded: {
            LabeledContent(tr("skills.detail.source")) {
                Text(entry.source + " @ " + String(entry.commit.prefix(12)))
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textSecondary)
                    .textSelection(.enabled)
            }
            ForEach(entry.places, id: \.url) { place in
                LabeledContent(place.providers.map(\.displayName).joined(separator: ", ")) {
                    Text(AgentPathFormat.tilde(place.url.path))
                        .font(NookTheme.mono(11))
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            if !entry.scripts.isEmpty {
                SettingNote(tr("skills.detail.scripts", entry.scripts.count), tone: .warning)
            }
            if let update {
                StepAction(detail: changeText(update.change), button: tr("skills.update")) { sheet = .update(entry, update) }
            }
        }
    }

    private func changeText(_ change: SkillChange?) -> String {
        guard let change else { return tr("skills.updates.newCommit") }
        return tr("skills.updates.changed", change.count)
    }

    // MARK: Find

    private var findSection: some View {
        Section {
            Toggle(isOn: $ws.skillsSearchOnline) {
                SettingLabel(tr("skills.search.online"), hint: tr("skills.search.onlineHint"))
            }
            if ws.skillsSearchOnline {
                NookSearchField(prompt: tr("skills.search.prompt"), text: $query, style: .inline)
                    .onChange(of: query) { _, text in store.search(text) }
                if store.searching {
                    BusyLine(tr("skills.search.busy"), tone: .tertiary, font: NookTheme.TextStyle.detail)
                } else if let error = store.searchError {
                    SettingNote(error, tone: .warning)
                } else if query.trimmingCharacters(in: .whitespaces).count >= 2, store.hits.isEmpty {
                    ListEmptyNote(tr("skills.search.none"))
                }
                ForEach(store.hits.prefix(12)) { hit in
                    SkillHitRow(title: hit.name, detail: tr("skills.search.hitDetail", hit.repository.slug, hit.installs.formatted()),
                                installed: isInstalled(hit)) {
                        sheet = .preview(.hit(hit))
                    }
                }
            }
        } header: {
            SettingsSectionTitle(tr("skills.search.title"), info: tr("skills.search.info"))
        }
    }

    private func isInstalled(_ hit: SkillSearchHit) -> Bool {
        store.installed.contains { $0.repository.lowercased() == hit.repository.slug.lowercased()
            && ($0.places[0].provenance.folder as NSString).lastPathComponent.lowercased() == hit.skillID.lowercased() }
    }

    // MARK: Collections

    private var collectionsSection: some View {
        let sources = SkillSources.all(added: ws.skillSources, claude: SkillSources.claudeMarketplaces(home: store.home))
        let added = Set(ws.skillSources.compactMap(SkillRepository.parse))
        return Section {
            ForEach(sources, id: \.self) { repository in
                HStack(spacing: NookTheme.Spacing.md) {
                    SkillHitRow(title: repository.slug + (repository.folder.map { "/" + $0 } ?? ""),
                                detail: sourceDetail(repository, added: added.contains(repository)), installed: false) {
                        sheet = .browse(repository)
                    }
                    if added.contains(repository) {
                        ConfirmedButton(symbol: "trash", title: tr("skills.sources.remove"),
                                        question: tr("confirm.remove", repository.slug), detail: tr("skills.sources.removeDetail")) {
                            ws.skillSources.removeAll { SkillRepository.parse($0) == repository }
                        }
                        .labelled(tr("skills.sources.remove"))
                        .buttonStyle(.nookBorderless)
                    }
                }
            }
        } header: {
            ConnectionListHeader(title: tr("skills.sources.title"), info: tr("skills.sources.info"),
                                 add: (tr("skills.sources.add"), { addingSource = true }))
        }
    }

    private func sourceDetail(_ repository: SkillRepository, added: Bool) -> String {
        if added { return tr("skills.sources.yours") }
        if SkillSources.defaults.contains(repository.slug) { return tr("skills.sources.builtIn") }
        return tr("skills.sources.claude")
    }
}

/// A skill or a repository in a list: its name, one line under it, "Installed" when it is, and the arrow that says a
/// click opens it.
private struct SkillHitRow: View {
    let title: String
    let detail: String
    let installed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper).lineLimit(1)
                        if installed { NookTag(tr("skills.installed.tag")) }
                    }
                    Text(detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(icon: "chevron.right")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, NookTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
    }
}

// MARK: - The sheet

/// What the skill sheet opens on: a search hit or a skill to preview, a repository to browse, or an update to check.
enum SkillSheetRoute: Identifiable {
    enum Target {
        case hit(SkillSearchHit)
        case skill(RemoteSkill)
    }

    case preview(Target)
    case browse(SkillRepository)
    case update(SkillLibraryEntry, SkillsStore.Update)

    var id: String {
        switch self {
        case .preview(.hit(let hit)): return "hit:" + hit.id
        case .preview(.skill(let skill)): return "skill:" + skill.id
        case .browse(let repository): return "browse:" + repository.slug + (repository.folder ?? "")
        case .update(let entry, _): return "update:" + entry.id
        }
    }
}

/// One sheet for every way to a skill: browsing a repository leads to a skill's preview in the same sheet, and the
/// preview installs or updates it. The preview is the check: what the agent will read (SKILL.md), every file with its
/// size, each script with its text, and the commit it is pinned to.
private struct SkillSheet: View {
    let route: SkillSheetRoute
    let scope: SkillScope
    let providers: [RunProvider]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SkillsStore.shared

    // Browsing
    @State private var listed: [RemoteSkill] = []
    @State private var filter = ""
    // The skill shown
    @State private var skill: RemoteSkill?
    @State private var skillText: String?
    @State private var loading = true
    @State private var error: String?
    // Installing
    @State private var installing = false
    @State private var fraction: Double = 0
    @State private var installError: String?
    @State private var clash: (name: String, provenance: SkillProvenance)?
    @State private var askReplace = false

    var body: some View {
        SetupSheet(title: title, subtitle: subtitle, width: 600) {
            SettingsTile(.agents, size: 40)
        } content: {
            if loading {
                PatientSpinner().frame(maxWidth: .infinity, minHeight: 200)
            } else if let error {
                SettingNote(error, tone: .warning)
            } else if let skill {
                preview(skill)
            } else {
                browseList
            }
        } footer: {
            if skill != nil, isBrowse {
                Button(tr("skills.sheet.back")) {
                    skill = nil
                    skillText = nil
                    installError = nil
                }
            }
            if installing {
                BusyLine(tr("skills.sheet.downloading", Int(fraction * 100)), font: NookTheme.TextStyle.detail)
            }
            Spacer()
            Button(tr("button.cancel")) { dismiss() }
                .sheetCancelButton()
            if skill != nil {
                Button(isUpdate ? tr("skills.update") : tr("skills.install")) { install(replace: false) }
                    .sheetPrimaryButton()
                    .disabled(installing || skill?.refusal != nil || providers.isEmpty)
            }
        }
        .interactiveDismissDisabled(installing)
        .confirmationDialog(tr("skills.replace.question", clash?.name ?? ""), isPresented: $askReplace, titleVisibility: .visible) {
            Button(tr("skills.replace")) { install(replace: true) }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: {
            if let clash { Text(tr("skills.replace.detail", clash.provenance.repository)) }
        }
        .task { await load() }
    }

    private var isBrowse: Bool { if case .browse = route { return true } else { return false } }
    private var isUpdate: Bool { if case .update = route { return true } else { return false } }

    private var title: String {
        if let skill { return skill.name }
        switch route {
        case .preview(.hit(let hit)): return hit.name
        case .preview(.skill(let skill)): return skill.name
        case .browse(let repository): return repository.slug
        case .update(let entry, _): return entry.name
        }
    }

    private var subtitle: String {
        if let skill { return tr("skills.sheet.from", skill.repository.slug, String(skill.commit.prefix(7))) }
        if case .browse = route { return tr("skills.sheet.browse") }
        return tr("skills.sheet.loading")
    }

    // MARK: Loading

    private func load() async {
        let fetcher = store.fetcher
        do {
            switch route {
            case .preview(.hit(let hit)):
                show(try await fetcher.resolve(hit), fetcher)
            case .preview(.skill(let skill)):
                show(try await fetcher.describe(skill), fetcher)
            case .update(_, let update):
                show(try await fetcher.describe(update.remote), fetcher)
            case .browse(let repository):
                let commit = try await fetcher.commit(of: repository)
                var found = try await fetcher.skills(in: repository, at: commit)
                loading = false
                listed = found
                // Names and descriptions from each SKILL.md, a few at a time, so the list fills in as they come.
                for start in stride(from: 0, to: min(found.count, 300), by: 6) {
                    let chunk = Array(found[start..<min(start + 6, found.count)])
                    let described = await withTaskGroup(of: RemoteSkill?.self) { group in
                        for skill in chunk { group.addTask { try? await fetcher.describe(skill) } }
                        return await group.reduce(into: [RemoteSkill]()) { if let s = $1 { $0.append(s) } }
                    }
                    for skill in described { if let i = found.firstIndex(where: { $0.id == skill.id }) { found[i] = skill } }
                    listed = found
                }
            }
        } catch {
            self.error = SkillsStore.message(error)
        }
        loading = false
    }

    private func show(_ remote: RemoteSkill, _ fetcher: SkillFetcher) {
        skill = remote
        loading = false
        Task {
            if let data = try? await fetcher.file(remote, path: "SKILL.md") {
                skillText = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
            }
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var browseList: some View {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = needle.isEmpty ? listed : listed.filter {
            $0.name.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
        }
        NookSearchField(prompt: tr("skills.sheet.filter"), text: $filter, style: .inline)
        if shown.isEmpty {
            ListEmptyNote(listed.isEmpty ? tr("skills.sheet.noSkills") : tr("skills.search.none"))
        }
        LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            ForEach(shown) { remote in
                SettingsPickRow(title: remote.name, detail: remote.description.isEmpty ? remote.folder : remote.description,
                                selected: false) {
                    show(remote, store.fetcher)
                }
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func preview(_ skill: RemoteSkill) -> some View {
        if !skill.description.isEmpty {
            Text(skill.description)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let refusal = skill.refusal {
            SettingNote(SkillsStore.refusalText(refusal), tone: .error)
        }
        if case .update(_, let update) = route, let change = update.change {
            SheetPart(tr("skills.sheet.changes")) {
                changeList(change)
            }
        }
        SheetPart(tr("skills.sheet.where")) {
            let roots = SkillPlaces.roots(for: providers, scope: scope, home: store.home)
            if isUpdate, case .update(let entry, _) = route {
                ForEach(entry.places, id: \.url) { place in pathLine(place.url.deletingLastPathComponent()) }
            } else {
                ForEach(roots, id: \.self) { root in pathLine(root) }
                Text(tr("skills.sheet.forAgents", providers.map(\.displayName).joined(separator: ", ")))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
        SheetPart(tr("skills.sheet.contents")) {
            Text(tr("skills.sheet.size", skill.files.count, SkillsStore.byteText(skill.totalBytes)))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
            if skill.totalBytes > SkillLimits.largeSkillBytes {
                SettingNote(tr("skills.sheet.large"), tone: .warning)
            }
            if skill.scripts.isEmpty {
                SettingNote(tr("skills.sheet.noScripts"), tone: .success)
            } else {
                SettingNote(tr("skills.sheet.scripts", skill.scripts.count), tone: .warning)
                ForEach(skill.scripts.prefix(50), id: \.path) { file in
                    SkillScriptRow(skill: skill, file: file)
                }
                if skill.scripts.count > 50 {
                    Text(tr("skills.sheet.moreScripts", skill.scripts.count - 50))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
        }
        SheetPart("SKILL.md") {
            if let skillText {
                ScrollView {
                    Text(skillText)
                        .font(NookTheme.TextStyle.code)
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                NookSkeletonLines()
            }
        }
        if let installError {
            InlineErrorText(installError)
        }
    }

    private func pathLine(_ url: URL) -> some View {
        Text(AgentPathFormat.tilde(url.path))
            .font(NookTheme.mono(11))
            .foregroundStyle(NookTheme.textSecondary)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func changeList(_ change: SkillChange) -> some View {
        let lines = change.added.map { ("+", $0, NookTheme.diffAdded) } + change.changed.map { ("~", $0, NookTheme.diffModified) }
            + change.removed.map { ("−", $0, NookTheme.diffRemoved) }
        ForEach(lines.prefix(40), id: \.1) { mark, path, color in
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(mark).font(NookTheme.mono(11, .bold)).foregroundStyle(color).frame(width: 10)
                Text(path).font(NookTheme.mono(11)).foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.middle)
            }
        }
        if !change.scripts.isEmpty {
            SettingNote(tr("skills.sheet.changedScripts", change.scripts.count), tone: .warning)
        }
    }

    // MARK: Install

    private func install(replace: Bool) {
        guard let skill else { return }
        installing = true
        installError = nil
        fraction = 0
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor in fraction = total == 0 ? 1 : Double(done) / Double(total) }
        }
        Task {
            let outcome: SkillsStore.Outcome
            if case .update(let entry, _) = route {
                outcome = await store.update(entry, to: skill, progress: progress)
            } else {
                outcome = await store.install(skill, providers: providers, scope: scope, replace: replace, progress: progress)
            }
            installing = false
            switch outcome {
            case .installed:
                ToastCenter.shared.success(isUpdate ? tr("skills.updated", skill.name) : tr("skills.installedToast", skill.name))
                dismiss()
            case .otherSource(let name, let provenance):
                clash = (name, provenance)
                askReplace = true
            case .failed(let message):
                installError = message
            }
        }
    }
}

/// A script in the preview: its path and size, and its text once opened, so you can read what an agent may run.
private struct SkillScriptRow: View {
    let skill: RemoteSkill
    let file: SkillFile
    @State private var open = false
    @State private var text: String?

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Group {
                if let text {
                    ScrollView {
                        Text(text)
                            .font(NookTheme.TextStyle.code)
                            .foregroundStyle(NookTheme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                } else {
                    NookSkeletonLines()
                }
            }
            .task(id: open) {
                guard open, text == nil else { return }
                let data = try? await SkillsStore.shared.fetcher.file(skill, path: file.path)
                text = data.map { String(decoding: $0.prefix(64 * 1024), as: UTF8.self) } ?? tr("skills.error.unreadable")
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(file.path).font(NookTheme.mono(11)).foregroundStyle(NookTheme.paper).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(SkillsStore.byteText(file.size)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            }
        }
    }
}

/// Adding a GitHub repository to browse: "owner/repo" or a link to it (or to a folder in it).
private struct SkillSourceSheet: View {
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var parsed: SkillRepository? { SkillRepository.parse(text) }

    var body: some View {
        SetupSheet(title: tr("skills.sources.addTitle"), subtitle: tr("skills.sources.addSubtitle"), width: 460) {
            SettingsTile(.agents, size: 40)
        } content: {
            SetupStep(number: 1, title: tr("skills.sources.repository"), done: parsed != nil) {
                TextField("", text: $text, prompt: Text("owner/repo").foregroundStyle(NookTheme.textTertiary))
                    .settingsField()
                    .font(NookTheme.TextStyle.code)
                if !text.isEmpty, parsed == nil {
                    SettingNote(tr("skills.sources.bad"), tone: .warning)
                }
            }
        } footer: {
            Spacer()
            Button(tr("button.cancel")) { dismiss() }
                .sheetCancelButton()
            Button(tr("skills.sources.addButton")) {
                if let parsed { add(SkillSources.stored(parsed)) }
                dismiss()
            }
            .sheetPrimaryButton()
            .disabled(parsed == nil)
        }
    }
}
