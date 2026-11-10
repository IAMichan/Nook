import AppKit
import SwiftUI
import WebKit

/// Settings › Browser: the row that opens the import of another browser's sign-ins.
struct BrowserImportRow: View {
    @State private var open = false

    var body: some View {
        LabeledContent {
            Button(tr("cookieImport.open")) { open = true }
        } label: {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                SettingText("cookieImport.title")
                SettingNote(tr("cookieImport.detail"))
            }
        }
        .sheet(isPresented: $open) { BrowserImportSheet() }
    }
}

/// A one-time copy of another browser's sign-ins into Nook's browser: pick the browser and its profile, read its
/// cookies (macOS asks for the Keychain password of a Chromium browser, Safari needs Full Disk Access), pick the sites,
/// and where they go: Nook's own browser or a project's. See `BrowserCookieImporter`.
struct BrowserImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ws = WorkspaceSettings.shared

    private enum Phase: Equatable {
        case choosing
        case reading
        case picking
        case importing
        case done(cookies: Int, sites: Int)
    }

    @State private var sources: [BrowserImportSource] = []
    @State private var sourceID = ""
    @State private var profiles: [BrowserImportProfile] = []
    @State private var profileID = ""
    @State private var phase = Phase.choosing
    @State private var problem: CookieReadError?
    @State private var cookies: [ImportedCookie] = []
    @State private var skipped = 0
    @State private var sites: [CookieSite] = []
    @State private var chosen: Set<String> = []
    @State private var filter = ""
    /// Where the sign-ins go: "" for Nook's own browser, else a project's folder.
    @State private var target = ""

    private var source: BrowserImportSource? { sources.first { $0.id == sourceID } }
    private var profile: BrowserImportProfile? { profiles.first { $0.id == profileID } }
    private var shownSites: [CookieSite] {
        filter.isEmpty ? sites : sites.filter { $0.domain.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        SetupSheet(title: tr("cookieImport.title"), subtitle: tr("cookieImport.subtitle"), width: 520) {
            SettingsTile(.openIn, size: 40)
        } content: {
            if sources.isEmpty {
                ListEmptyNote(tr("cookieImport.none"))
            } else {
                SetupStep(number: 1, title: tr("cookieImport.step.source"), done: phase != .choosing && phase != .reading) {
                    sourcePickers
                }
                SetupStep(number: 2, title: tr("cookieImport.step.sites"), done: { if case .done = phase { return true }; return false }()) {
                    sitePicker
                }
            }
        } footer: {
            footer
        }
        .onAppear(perform: load)
    }

    // MARK: Step 1

    @ViewBuilder
    private var sourcePickers: some View {
        Picker(tr("cookieImport.browser"), selection: Binding(get: { sourceID }, set: { choose(source: $0) })) {
            ForEach(sources) { Text($0.name).tag($0.id) }
        }
        if profiles.count > 1 {
            Picker(tr("cookieImport.profile"), selection: Binding(get: { profileID }, set: { profileID = $0; reset() })) {
                ForEach(profiles) { Text($0.name).tag($0.id) }
            }
        }
        if profiles.isEmpty {
            SettingNote(tr("cookieImport.noProfile"), tone: .warning)
        } else if case .chromium = source?.engine {
            SettingNote(tr("cookieImport.keychainNote", source?.name ?? ""))
        } else if source?.engine == .firefox {
            SettingNote(tr("cookieImport.firefoxNote"))
        }
        if let problem { problemNote(problem) }
        if phase == .choosing || phase == .reading {
            HStack(spacing: NookTheme.Spacing.md) {
                Button(tr("cookieImport.read")) { read() }
                    .disabled(profile == nil || phase == .reading)
                if phase == .reading { ProgressView().controlSize(.small) }
            }
        }
    }

    @ViewBuilder
    private func problemNote(_ problem: CookieReadError) -> some View {
        switch problem {
        case .needsFullDiskAccess:
            SettingNote(tr("cookieImport.fullDiskAccess"), tone: .warning)
            HStack(spacing: NookTheme.Spacing.md) {
                Button(tr("cookieImport.openPrivacy")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(tr("cookieImport.checkAgain")) { read() }
            }
        case .keychainDenied:
            SettingNote(tr("cookieImport.keychainDenied", source?.name ?? ""), tone: .warning)
        case .malformed, .unreadable:
            SettingNote(tr("cookieImport.unreadable", source?.name ?? ""), tone: .error)
        }
    }

    // MARK: Step 2

    @ViewBuilder
    private var sitePicker: some View {
        switch phase {
        case .choosing, .reading:
            SettingNote(tr("cookieImport.sites.waiting"))
        case .done(let count, let siteCount):
            SettingNote(tr("cookieImport.done", count, siteCount), tone: .success)
        case .picking, .importing:
            if sites.isEmpty {
                ListEmptyNote(tr("cookieImport.sites.empty"))
            } else {
                HStack(spacing: NookTheme.Spacing.md) {
                    TextField("", text: $filter, prompt: Text(tr("cookieImport.sites.search")))
                        .textFieldStyle(.roundedBorder)
                    Button(tr("cookieImport.sites.all")) { chosen.formUnion(shownSites.map(\.domain)) }
                    Button(tr("cookieImport.sites.clear")) { chosen.subtract(shownSites.map(\.domain)) }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                        ForEach(shownSites) { site in
                            Toggle(isOn: Binding(get: { chosen.contains(site.domain) },
                                                 set: { if $0 { chosen.insert(site.domain) } else { chosen.remove(site.domain) } })) {
                                HStack {
                                    Text(site.domain)
                                    Spacer(minLength: NookTheme.Spacing.md)
                                    Text(tr("cookieImport.sites.count", site.count))
                                        .font(NookTheme.TextStyle.detail)
                                        .foregroundStyle(NookTheme.textTertiary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 220)
                if skipped > 0 { SettingNote(tr("cookieImport.skipped", skipped)) }
            }
            Picker(tr("cookieImport.into"), selection: $target) {
                Text(tr("cookieImport.into.nook")).tag("")
                ForEach(ProjectSettings.scopeChoices(favorites: ws.favoriteProjects, recent: ws.recentProjects,
                                                     overrides: ws.projectOverrides), id: \.self) { path in
                    Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                }
            }
            SettingNote(tr("cookieImport.into.note"))
        }
    }

    @ViewBuilder
    private var footer: some View {
        Spacer()
        if case .done = phase {
            Button(tr("button.done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else {
            Button(tr("button.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button(tr("cookieImport.import")) { Task { await importChosen() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(phase != .picking || chosen.isEmpty)
        }
    }

    // MARK: Actions

    private func load() {
        sources = BrowserCookieImporter.installed()
        if sourceID.isEmpty, let first = sources.first { choose(source: first.id) }
    }

    private func choose(source id: String) {
        sourceID = id
        profiles = sources.first { $0.id == id }.map { BrowserCookieImporter.profiles(of: $0) } ?? []
        profileID = profiles.first?.id ?? ""
        reset()
    }

    private func reset() {
        phase = .choosing
        problem = nil
        cookies = []
        sites = []
        chosen = []
        skipped = 0
    }

    private func read() {
        guard let source, let profile else { return }
        problem = nil
        phase = .reading
        Task { @MainActor in
            do {
                let found = try await BrowserCookieImporter.read(source, profile)
                cookies = found.cookies
                skipped = found.skipped
                sites = CookieSites.group(found.cookies, now: Date())
                phase = .picking
            } catch {
                problem = error as? CookieReadError ?? .unreadable
                phase = .choosing
            }
        }
    }

    private func importChosen() async {
        let picked = CookieSites.picking(cookies, sites: chosen, now: Date())
        guard !picked.isEmpty else { return }
        phase = .importing
        let project = target.isEmpty ? nil : target
        // Imported sign-ins are meant to stay: the browser they go to keeps sign-ins from now on.
        if let project {
            ws.setOverride(.browserSignIns, BrowserSignInPolicy.keep.stored, for: project)
        } else if ws.browserSignInPolicy != .keep {
            ws.browserSignInPolicy = .keep
        }
        var stores = [BrowserProfiles.keptStore(project: project)]
        // Nook's own browser may be open on a store that forgot sign-ins until now: it gets them too, for this run.
        if project == nil, let open = BrowserStore.existing?.websiteDataStore, open !== stores[0] { stores.append(open) }
        let written = await BrowserCookieImporter.write(picked, into: stores)
        phase = .done(cookies: written, sites: chosen.count)
        // What was read stays no longer than needed.
        cookies = []
    }
}
