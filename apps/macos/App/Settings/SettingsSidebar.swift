import SwiftUI
import AppKit

/// The measures of the Settings window: a 240 pt sidebar, a 48 pt bar over the page, and a page that
/// keeps to a readable width however wide the window is.
enum SettingsLayout {
    static let sidebarWidth: CGFloat = 240
    static let barHeight: CGFloat = 48
    static let pageWidth: CGFloat = 860
    /// Room above the sidebar's search for the window's traffic lights.
    static let trafficLightInset: CGFloat = 40
}

/// The sidebar of Settings: a search row on top (⌘F or / puts the keyboard in it), then the pages in their
/// groups, each a line icon and a name. While you search, the pages give way to what matches, with the page each lives
/// on; ↑ and ↓ move through them and Return opens one. A view of its own, so a keystroke in the search redraws only the
/// sidebar, not every page and count of Settings.
struct SettingsSidebar: View {
    @EnvironmentObject var app: AppModel
    /// The count on each section's row; a section without one shows none.
    var badges: [SettingsSection: Int]
    @State private var query = ""
    /// The result Return opens, moved with ↑ and ↓.
    @State private var active = 0
    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let hits = SettingsSearch.results(query)
        VStack(alignment: .leading, spacing: 0) {
            searchRow(hits)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.top, SettingsLayout.trafficLightInset)
                .padding(.bottom, NookTheme.Spacing.md)
            ScrollViewReader { proxy in
                ScrollView {
                    if searching {
                        results(hits)
                    } else {
                        pages
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: active) { _, index in
                    guard hits.indices.contains(index) else { return }
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(hits[index].id) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NookTheme.surface)
        .onAppear(perform: watchKeys)
        .onDisappear(perform: stopWatchingKeys)
    }

    // MARK: Search

    private func searchRow(_ hits: [SettingsSearchHit]) -> some View {
        NookSearchField(prompt: tr("settings.search.prompt"), text: $query, focus: $searchFocused,
                        onSubmit: { open(hits) }, onEscape: { searchFocused = false })
            .overlay(alignment: .trailing) {
                // The key that finds a setting, shown until you type.
                if query.isEmpty {
                    NookKeyHint(text: "/").padding(.trailing, NookTheme.Spacing.sm)
                }
            }
            .onChange(of: query) { _, _ in active = 0 }
            .onKeyPress(.downArrow) {
                guard !hits.isEmpty else { return .ignored }
                active = (active + 1) % hits.count
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !hits.isEmpty else { return .ignored }
                active = (active - 1 + hits.count) % hits.count
                return .handled
            }
    }

    /// ⌘F anywhere in Settings, and / where no text is being edited, put the keyboard in the search.
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = app.settingsWindow, event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let find = modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "f"
            let slash = modifiers.subtracting(.shift).isEmpty && event.characters == "/"
                && !(window.firstResponder is NSText)
            guard find || slash else { return event }
            searchFocused = true
            return nil
        }
    }

    private func stopWatchingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func open(_ hits: [SettingsSearchHit]) {
        guard hits.indices.contains(active) else { return }
        let hit = hits[active]
        app.openSettings(section: hit.section, highlight: hit.isSection ? nil : hit.key)
        query = ""
        searchFocused = false
    }

    private func results(_ hits: [SettingsSearchHit]) -> some View {
        LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            if hits.isEmpty {
                Text(tr("settings.search.none"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, NookTheme.Spacing.xl)
            }
            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                SettingsSidebarRow(symbol: hit.section.sidebarSymbol, title: hit.title, detail: hit.section.trail,
                                   selected: index == active) {
                    active = index
                    open(hits)
                }
                .id(hit.id)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.bottom, NookTheme.Spacing.lg)
    }

    // MARK: Pages

    private var pages: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            ForEach(SettingsSection.Group.allCases) { group in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    if let title = group.title {
                        NookSectionLabel(title, inset: NookTheme.Spacing.sm)
                            .padding(.bottom, NookTheme.Spacing.xxs)
                    }
                    ForEach(group.sections) { section in
                        SettingsSidebarRow(symbol: section.sidebarSymbol, title: section.pageTitle,
                                           selected: app.settingsSection.host == section,
                                           badge: badges[section] ?? 0) {
                            guard app.settingsSection != section else { return }
                            app.settingsSection = section
                        }
                    }
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.bottom, NookTheme.Spacing.lg)
    }
}

/// One row of the Settings sidebar: a line icon, the page's (or setting's) name, the page it is on for a search result,
/// and a count of what needs you.
struct SettingsSidebarRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    let selected: Bool
    var badge = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: symbol)
                    .font(NookTheme.font(13))
                    .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(selected ? NookTheme.paper : NookTheme.textStrong)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                NookCountBadge(count: badge)
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(minHeight: detail == nil ? 30 : 40)
            .hoverRowFill(selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The bar over a page: where you are (Settings › page) and on the right Restore defaults. What the page holds is
/// written at the top of the page itself (`SettingsPageIntro`), not hidden here. Adding sits in the header of the list
/// it adds to ("+ Add machine"), not here.
struct SettingsPageBar: View {
    let section: SettingsSection
    /// Watched so "Restore defaults" dims the moment nothing on the page differs from the defaults any more.
    @ObservedObject private var inbox = InboxStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var colorEdits = NookColorEdits.shared
    @AppStorage(AppDelegate.confirmQuitKey) private var confirmQuit = true
    @AppStorage(QuitHoldMonitor.enabledKey) private var holdToQuit = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(tr("settings.crumb.root")).foregroundStyle(NookTheme.textTertiary)
            crumbChevron
            Text(section.pageTitle)
                .foregroundStyle(NookTheme.paper)
            Spacer(minLength: NookTheme.Spacing.lg)
            if let restore = SettingsRestore(section) {
                // Put this page's own settings back to how Nook ships, after asking.
                ConfirmedButton(question: tr("settings.restore.question", section.pageTitle), confirmTitle: tr("settings.general.restore"),
                                action: {
                                    restore.run()
                                    ToastCenter.shared.success(tr("settings.general.restored"))
                                }) {
                    Label(tr("settings.general.restore"), icon: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(!restore.changed)
            }
        }
        .font(NookTheme.TextStyle.strong)
        .lineLimit(1)
        .padding(.horizontal, NookTheme.Spacing.xl)
        .frame(height: SettingsLayout.barHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var crumbChevron: some View {
        Image(icon: "chevron.right")
            .font(NookTheme.font(9, .semibold))
            .foregroundStyle(NookTheme.textMuted)
            .accessibilityHidden(true)
    }
}

/// The top of every Settings page: its name in large type, one line on what it holds, what it means for your data
/// when that matters, and for a page of several subjects a button per subject that scrolls to it. So you see what a
/// page is for before reading a single row.
struct SettingsPageIntro: View {
    let section: SettingsSection
    /// Marks the intro as the first subject's place, for a page whose first subject has no heading of its own.
    var anchorsFirstPart = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                Text(section.pageTitle)
                    .font(NookTheme.TextStyle.display)
                    .foregroundStyle(NookTheme.paper)
                    .accessibilityAddTraits(.isHeader)
                Text(section.pageSubtitle)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let info = section.info {
                    Text(info)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if section.parts.count > 1 {
                    ChipFlow(spacing: NookTheme.Spacing.xs) {
                        ForEach(section.parts) { part in
                            SettingsPartChip(part: part)
                        }
                    }
                    .padding(.top, NookTheme.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(OptionalSettingsAnchor(title: anchorsFirstPart ? section.title : nil))
        }
        .settingsBareSection()
    }
}

/// Marks a view as a setting's place only when it has a name, so two views never claim the same place.
private struct OptionalSettingsAnchor: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content.settingsAnchor(title)
        } else {
            content
        }
    }
}

/// Whether a subject of a page shows right now: the parts of autocomplete only while completing is on.
@MainActor
enum SettingsPartVisibility {
    static func shows(_ part: SettingsSection) -> Bool {
        switch part {
        case .autocompleteApps, .autocompleteStyle, .autocompletePlayground, .autocompleteStats:
            return AutocompleteStore.shared.prefs.enabled
        default:
            return true
        }
    }
}

/// One subject of a page as a button at the top of that page: a click scrolls to the subject's heading.
struct SettingsPartChip: View {
    let part: SettingsSection
    /// Watched so the parts of autocomplete come and go with its switch.
    @ObservedObject private var autocomplete = AutocompleteStore.shared

    var body: some View {
        if SettingsPartVisibility.shows(part) {
            chip
        }
    }

    private var chip: some View {
        Button {
            // Cleared first, so a second click on the same subject scrolls again.
            SettingsHighlight.shared.key = nil
            DispatchQueue.main.async { SettingsHighlight.shared.key = "settings.section.\(part.rawValue)" }
        } label: {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(icon: part.sidebarSymbol)
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textSecondary)
                Text(part.title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textStrong)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.xs)
            .hoverRowFill(selected: false, radius: NookTheme.Radius.chip, rest: NookTheme.surface)
            .roundedStrokeBorder(NookTheme.separator, radius: NookTheme.Radius.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .help(part.subtitle)
    }
}

/// The heading of one subject on a page of several: a line above it, its tile, its name, what it is for, and what it
/// means for your data when that matters. A search for the subject (or its button at the top) scrolls here.
struct SettingsPartHeader: View {
    let part: SettingsSection
    /// Watched so the parts of autocomplete come and go with its switch.
    @ObservedObject private var autocomplete = AutocompleteStore.shared

    var body: some View {
        if SettingsPartVisibility.shows(part) {
            header
        }
    }

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                NookDivider()
                HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
                    SettingsTile(part, size: 30)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(part.title)
                            .font(NookTheme.TextStyle.heading)
                            .foregroundStyle(NookTheme.paper)
                        Text(part.subtitle)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let info = part.info {
                            Text(info)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .settingsAnchor(part.title)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, NookTheme.Spacing.lg)
        }
        .settingsBareSection()
    }
}

/// "Restore defaults" in the bar over a page, for the pages whose own settings have a default to go back to.
@MainActor
enum SettingsRestore {
    case general, appearance

    init?(_ section: SettingsSection) {
        switch section {
        case .general: self = .general
        case .appearance: self = .appearance
        default: return nil
        }
    }

    /// Something on the page differs from its default.
    var changed: Bool {
        switch self {
        case .general: return GeneralListAndConfirmations.changed
        case .appearance:
            let settings = AppSettings.shared
            return settings.nookLook != .classic || settings.accentHex != NookTheme.defaultAccentHex
                || settings.themeChoice != NookThemeChoice()
        }
    }

    func run() {
        switch self {
        case .general: GeneralListAndConfirmations.restoreDefaults()
        case .appearance:
            AppSettings.shared.nookLook = .classic
            AppSettings.shared.accentHex = NookTheme.defaultAccentHex
            AppSettings.shared.appearanceMode = .dark
            AppSettings.shared.darkThemeID = NookColorTheme.nook.id
            AppSettings.shared.lightThemeID = NookColorTheme.nook.id
            AppSettings.shared.colorOverrides = NookColorOverrides()
        }
    }
}
