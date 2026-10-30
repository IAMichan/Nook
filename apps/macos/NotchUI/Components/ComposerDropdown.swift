import SwiftUI

// Composer dropdowns in Nook: the quiet pill as trigger, and instead of a system menu a dark panel with rows.
// A section header, rows with an icon or logo, a title and a description, a faint fill on the chosen row (no check
// mark), disabled rows that say why, and a search field for long lists. The model pickers (agents, and Nook's own
// brain in the chat) share one split layout: a narrow rail of places on the left, their models on the right (ModelPicker.swift).

/// A composer choice that opens a custom dropdown panel under its pill.
struct ComposerDropdown<Trigger: View, Content: View>: View {
    var width: CGFloat = 264
    /// The trigger is a logo pill that may show its text in the room a crowded composer row has left.
    var takesRoom = false
    @ViewBuilder let trigger: () -> Trigger
    @ViewBuilder let content: () -> Content
    @Environment(\.composerDensity) private var density
    @State private var open = false

    var body: some View {
        let flexible = takesRoom && density.logosTakeRoom
        Button { open.toggle() } label: { trigger() }
            .buttonStyle(.plain)
            .fixedSize(horizontal: !flexible, vertical: true)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                // The panel takes the height its rows ask for at this width, so wrapped text grows it instead of
                // being cut off, and it follows when a search or another place changes what it shows.
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(4)
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(DropdownStyle.panel)
                    .environment(\.closeDropdown, { open = false })
            }
            // Ahead of the spacer, so the pill gets all the room left instead of half of it.
            .layoutPriority(flexible ? 1 : 0)
    }
}

enum DropdownStyle {
    static let panel = Color(hex: 0x17171C)
    static let hover = NookTheme.smoke
    static let chosen = NookTheme.paper.opacity(0.08)
}

private struct DropdownCloseKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Closes the dropdown a row belongs to.
    var closeDropdown: () -> Void {
        get { self[DropdownCloseKey.self] }
        set { self[DropdownCloseKey.self] = newValue }
    }
}

/// A small grey header over a group of rows.
struct DropdownHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.top, NookTheme.Spacing.md)
            .padding(.bottom, NookTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin line between groups.
struct DropdownDivider: View {
    var body: some View {
        NookDivider().padding(.horizontal, 8).padding(.vertical, 4)
    }
}

/// One choice: an optional symbol, agent logo or brand mark, a title, an optional description and trailing text.
/// The chosen row has a faint fill; a disabled row is dimmed and says why when you hover it.
struct DropdownRow: View {
    var symbol: String? = nil
    var agent: String? = nil
    var account: AccountKind? = nil
    var brand: BrandLogo? = nil
    let title: String
    var detail: String? = nil
    var trailing: String? = nil
    var chosen = false
    var tint: Color? = nil
    /// Draws the symbol in a small tile of this color instead of on its own (the chat composer's "+" menu).
    var tile: Color? = nil
    var disabledReason: String? = nil
    /// Keeps the panel open after the click (several choices in a row).
    var staysOpen = false
    /// A star at the end of the row (models and project folders): filled while the choice is a favorite, nil for none.
    var favorite: Binding<Bool>? = nil
    let action: () -> Void
    @Environment(\.closeDropdown) private var close
    @State private var hovering = false

    var body: some View {
        Button {
            guard disabledReason == nil else { return }
            action()
            if !staysOpen { close() }
        } label: {
            HStack(alignment: detail == nil ? .center : .top, spacing: tile == nil ? 8 : NookTheme.Spacing.md) {
                if let agent {
                    AgentMark(agent: agent, account: account, size: 15, ring: DropdownStyle.panel)
                } else if let brand {
                    BrandMark(logo: brand, size: 14)
                } else if let symbol, let tile {
                    NookSymbol(symbol, size: 13)
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(tile)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                            .fill(tile.opacity(hovering ? 0.24 : 0.16)))
                } else if let symbol {
                    NookSymbol(symbol, size: 13)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(tint ?? NookTheme.textSecondary)
                        .frame(width: 15)
                        .padding(.top, detail == nil ? 0 : 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(tint ?? NookTheme.paper)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
                }
                // Room for the star, which sits on top of the row as a button of its own.
                if favorite != nil { Color.clear.frame(width: 14, height: 14) }
            }
            .padding(.horizontal, tile == nil ? NookTheme.Spacing.md : NookTheme.Spacing.sm)
            .padding(.vertical, detail == nil ? (tile == nil ? NookTheme.Spacing.sm : NookTheme.Spacing.xs) : NookTheme.Spacing.md)
            .frame(minHeight: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(chosen ? DropdownStyle.chosen : (hovering && disabledReason == nil ? DropdownStyle.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { star }
        .opacity(disabledReason == nil ? 1 : 0.64)
        .onHover { hovering = $0 }
        .help(disabledReason ?? "")
    }

    @ViewBuilder
    private var star: some View {
        if let favorite, favorite.wrappedValue || hovering {
            let starred = favorite.wrappedValue
            Button { favorite.wrappedValue.toggle() } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(starred ? NookTheme.paper : NookTheme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, NookTheme.Spacing.xs)
            .help(tr(starred ? "compose.favoriteRemove" : "compose.favoriteAdd"))
            .accessibilityLabel(tr(starred ? "compose.favoriteRemove" : "compose.favoriteAdd"))
        }
    }
}

/// The search field on top of a long list (models, branches).
struct DropdownSearch: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        NookSearchField(prompt: placeholder, text: $text, style: .inline, focus: $focused)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .overlay(alignment: .bottom) { NookDivider() }
            .onAppear { focused = true }
    }
}

/// The split panel behind the model pickers: a narrow rail of places on the left (the agents, or this Mac and the
/// external AIs) and the shown place's choices on the right. Groups in the rail are split by a short line, and the place
/// in use gets a dot while you look at another one. A logo may carry its account badge. The rail hides when there is only one place and no footer.
struct RailDropdown<Place: Hashable, Icon: View, Footer: View, Detail: View>: View {
    let groups: [[Place]]
    /// The place in use; the panel opens on it.
    let chosen: Place
    let help: (Place) -> String
    /// Called when you switch to another place in the rail (to clear a search, say).
    let onShow: (Place) -> Void
    let icon: (Place) -> Icon
    /// Sits at the bottom of the rail (an "add" button).
    let footer: () -> Footer
    let detail: (Place) -> Detail
    private var hasFooter = true
    @State private var shown: Place?

    init(groups: [[Place]], chosen: Place,
         help: @escaping (Place) -> String, onShow: @escaping (Place) -> Void,
         @ViewBuilder icon: @escaping (Place) -> Icon,
         @ViewBuilder footer: @escaping () -> Footer,
         @ViewBuilder detail: @escaping (Place) -> Detail) {
        self.groups = groups
        self.chosen = chosen
        self.help = help
        self.onShow = onShow
        self.icon = icon
        self.footer = footer
        self.detail = detail
    }

    private var current: Place { shown ?? chosen }
    private var filledGroups: [[Place]] { groups.filter { !$0.isEmpty } }

    var body: some View {
        // Rail and column are as tall as the taller of the two, at the height they ask for: the rail's line runs to the
        // bottom with the "+" there, and a short column stays at the top instead of floating in the middle.
        HStack(alignment: .top, spacing: 0) {
            if hasFooter || filledGroups.joined().count > 1 { rail.frame(maxHeight: .infinity) }
            VStack(alignment: .leading, spacing: 0) { detail(current) }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(Array(filledGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle().fill(NookTheme.line2).frame(width: 18, height: 1).padding(.vertical, 2)
                }
                ForEach(group, id: \.self) { place in railButton(place) }
            }
            Spacer(minLength: 0)
            footer()
        }
        .padding(6)
        .frame(width: 44)
        .background(NookTheme.paper.opacity(0.03))
        .overlay(alignment: .trailing) { NookDivider(vertical: true) }
    }

    private func railButton(_ place: Place) -> some View {
        Button {
            shown = place
            onShow(place)
        } label: {
            icon(place)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                    .fill(place == current ? DropdownStyle.chosen : .clear))
                // Top corner: the bottom one holds the account badge.
                .overlay(alignment: .topTrailing) {
                    if place == chosen && place != current {
                        Circle().fill(NookTheme.paper.opacity(0.7)).frame(width: 4, height: 4).padding(4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(place))
    }
}

extension RailDropdown where Footer == EmptyView {
    init(groups: [[Place]], chosen: Place,
         help: @escaping (Place) -> String, onShow: @escaping (Place) -> Void,
         @ViewBuilder icon: @escaping (Place) -> Icon,
         @ViewBuilder detail: @escaping (Place) -> Detail) {
        self.init(groups: groups, chosen: chosen, help: help, onShow: onShow,
                  icon: icon, footer: { EmptyView() }, detail: detail)
        hasFooter = false
    }
}

/// A scrolling list of choices under a header or search field, with a note when there is nothing to show.
/// A ScrollView has no height of its own, so in a popover it would shrink to nothing under a header and account rows:
/// the list measures its rows and asks for that height, up to `maxHeight`, and never gives up the first few rows.
struct DropdownList<Rows: View>: View {
    var maxHeight: CGFloat = 260
    /// Shown instead of rows (nothing matches, nothing installed).
    var emptyNote: String? = nil
    @ViewBuilder let rows: () -> Rows
    @State private var contentHeight: CGFloat = 0

    /// About five rows stay visible when the panel runs out of room.
    private static var minVisible: CGFloat { 156 }

    var body: some View {
        let fitted = min(contentHeight, maxHeight)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let emptyNote {
                    Text(emptyNote)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .padding(10)
                }
                rows()
            }
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(minHeight: min(fitted, Self.minVisible), idealHeight: fitted, maxHeight: fitted)
    }
}

/// Model picker of the agents and of Nook's own brain in the chat: the connected agents in the rail, one logo per account
/// when an agent has several, and on the right the shown account's models, with a search field. The chat adds places
/// that are not an agent (this Mac's local models, an AI service with a key), which bring their own rows.
struct AgentModelPicker: View {
    @EnvironmentObject private var app: AppModel
    /// Favorites and typed models live here: a star redraws the menu at once.
    @ObservedObject private var ws = WorkspaceSettings.shared
    /// The agents you can pick from; one agent hides the rail (a running session keeps its agent).
    let providers: [RunProvider]
    let provider: RunProvider
    let profileID: String?
    let model: String
    var showsAccounts = false
    /// A new session can send its prompt to more models than the chosen one (`ModelComparison`): these are the others.
    /// Nil hides the choice (a running session).
    var comparing: Binding<[ComparisonTarget]>? = nil
    /// Places besides the agents, with their rows: this Mac's models first, AI services after the agents.
    var extraPlaces: [ModelPickerPlace] = []
    /// The place in use when it is one of `extraPlaces` rather than an agent.
    var chosenExtra: ModelPickerPlace? = nil
    var extraList: (ModelPickerPlace, String) -> ModelPickerList = { _, _ in ModelPickerList(models: []) }
    /// The chat's own words for the "+" and the Settings link; nil says the agents'.
    var addHelp: String? = nil
    var settingsTitle: String? = nil
    var settingsSection: SettingsSection = .agents
    let choose: (RunProvider, String?, String?) -> Void
    /// Picking a model adds it to the comparison instead of replacing the chosen one.
    @State private var multi = false

    /// One logo in the rail: an agent, or one of its accounts when it has several to pick from.
    private struct Place: Hashable {
        let provider: RunProvider
        /// Nil when the agent shows once: it runs under the account in use, or else the preferred one.
        let profileID: String?

        var id: String { [provider.rawValue, profileID].compactMap { $0 }.joined(separator: "/") }
    }

    /// Accounts get a logo of their own for a new session (a running session keeps its account).
    private var splitsAccounts: Bool { providers.count > 1 || showsAccounts }

    private var places: [Place] {
        providers.flatMap { current -> [Place] in
            let accounts = app.connectedProfiles(for: current)
            guard splitsAccounts, accounts.count > 1 else { return [Place(provider: current, profileID: nil)] }
            return accounts.map { Place(provider: current, profileID: $0.id) }
        }
    }

    private var chosenPlace: Place {
        let accounts = app.connectedProfiles(for: provider)
        guard splitsAccounts, accounts.count > 1 else { return Place(provider: provider, profileID: nil) }
        return Place(provider: provider, profileID: profileID ?? accounts.first?.id)
    }

    var body: some View {
        let shown = places
        ModelPicker(places: shown.map(pickerPlace) + extraPlaces, chosen: chosenExtra ?? pickerPlace(chosenPlace),
                    addHelp: addHelp ?? tr("agents.picker.add"), settingsTitle: settingsTitle ?? tr("agents.picker.settings"),
                    openSettings: { app.openSettings(section: settingsSection) }) { _ in
            if let comparing { compareToggle(comparing) }
        } list: { picked, query in
            shown.first { $0.id == picked.id }.map { models(of: $0, query: query) } ?? extraList(picked, query)
        }
    }

    private func pickerPlace(_ place: Place) -> ModelPickerPlace {
        ModelPickerPlace(id: place.id, name: place.provider.displayName, account: account(of: place), detail: accountLine(of: place))
    }

    private func isChosen(_ place: Place) -> Bool { chosenExtra == nil && place == chosenPlace }

    /// The account a place runs under: its own, the chosen one for the agent in use, else the one picking it would take.
    private func profile(of place: Place) -> AgentProfile? {
        let accounts = app.connectedProfiles(for: place.provider)
        let id = place.profileID ?? (place.provider == provider ? profileID : nil)
        return accounts.first(where: { $0.id == id }) ?? accounts.first
    }

    private func account(of place: Place) -> AccountKind? {
        profile(of: place).map { AccountKind.of($0, app: app) }
    }

    /// The account whose models the list shows: an ACP agent you added has models of its own.
    private func profileOf(_ place: Place) -> String? { profile(of: place)?.id }

    /// The account to hand back with a pick: nil keeps the one in use.
    private func pickedProfile(_ place: Place) -> String? { isChosen(place) ? nil : profileOf(place) }

    /// The account's name, when its agent shows once per account.
    private func accountLine(of place: Place) -> String? {
        guard place.profileID != nil, let profile = profile(of: place) else { return nil }
        return AccountLabel.line(profile, app: app)
    }

    private func models(of current: Place, query: String) -> ModelPickerList {
        var actions: [ModelPickerItem] = []
        if let custom = customModel(current, query: query) {
            actions.append(ModelPickerItem(id: "custom:" + custom, title: tr("compose.useModel", custom), symbol: "plus",
                                           detail: tr("compose.useModelDetail")) {
                ws.rememberCustomModel(custom, for: current.provider)
                choose(current.provider, pickedProfile(current), custom)
            })
        }
        return ModelPickerList(models: filtered(current, query: query).map { modelRow($0, of: current) }, actions: actions)
    }

    private func modelRow(_ option: String, of place: Place) -> ModelPickerItem {
        let current = place.provider
        let profile = profileOf(place)
        // A model that comes in thinking levels shows once; its level is picked with the effort control.
        let family = app.modelFamily(option, for: current, profileID: profile)
        let name = app.modelMenuName(option, for: current, profileID: profile)
        let choice = app.workspace.modelChoice(option, for: current, profileID: profile)
        let isChosen = isChosen(place)
            && (app.workspace.sameModel(option, model, for: current) || family?.contains(model) == true)
        let order = multi ? compareOrder(option, of: place, chosen: isChosen) : nil
        // A model that needs a newer agent says which update unlocks it, and cannot be picked until then.
        return ModelPickerItem(id: option,
                               title: name,
                               brand: BrandLogo.forName(option) ?? BrandLogo.forName(name) ?? BrandLogo.forName(current.displayName),
                               detail: app.modelUpdateNote(option, for: current)
                                   ?? (family != nil || option.isEmpty || name == option ? nil : option),
                               trailing: order.map { "\($0)" }
                                   ?? (choice?.isNew == true && choice?.needsUpdate == false ? tr("compose.modelNew") : nil),
                               chosen: multi ? order != nil : isChosen,
                               disabledReason: app.modelUpdateHelp(option, for: current),
                               staysOpen: multi,
                               favorite: option.isEmpty ? nil : favoriteBinding(option, for: current)) {
            if multi, let comparing {
                toggleCompared(option, of: place, in: comparing)
                return
            }
            let picked = app.menuPick(option, keeping: self.isChosen(place) ? model : "", for: current, profileID: profile)
            choose(current, pickedProfile(place), picked)
        }
    }

    // MARK: Several models

    /// "Send to several models": on, a click adds or removes a model next to the chosen one; off, the others are let go.
    private func compareToggle(_ comparing: Binding<[ComparisonTarget]>) -> some View {
        let on = multi || !comparing.wrappedValue.isEmpty
        return Group {
            DropdownRow(symbol: "square.stack.3d.up", title: tr("compare.toggle"),
                        detail: on ? tr("compare.toggleOn", ModelComparison.maxModels) : tr("compare.toggleDetail"),
                        trailing: on ? "\(comparing.wrappedValue.count + 1)" : nil, chosen: on, staysOpen: true) {
                if on {
                    multi = false
                    comparing.wrappedValue = []
                } else {
                    multi = true
                }
            }
            DropdownDivider()
        }
        .onAppear { if !comparing.wrappedValue.isEmpty { multi = true } }
    }

    private var primaryTarget: ComparisonTarget {
        ComparisonTarget(provider: provider, profileID: profileID ?? app.connectedProfiles(for: provider).first?.id ?? "", model: model)
    }

    private func target(_ option: String, of place: Place) -> ComparisonTarget {
        if isChosen(place) { return ComparisonTarget(provider: place.provider, profileID: primaryTarget.profileID, model: option) }
        return ComparisonTarget(provider: place.provider, profileID: profileOf(place) ?? "", model: option)
    }

    /// Where a model stands in the comparison (1 is the chosen one), nil when it is not part of it.
    private func compareOrder(_ option: String, of place: Place, chosen: Bool) -> Int? {
        if chosen { return 1 }
        let all = ModelComparison.targets(primary: primaryTarget, extras: comparing?.wrappedValue ?? [])
        return all.firstIndex(of: target(option, of: place)).map { $0 + 1 }
    }

    private func toggleCompared(_ option: String, of place: Place, in comparing: Binding<[ComparisonTarget]>) {
        comparing.wrappedValue = ModelComparison.toggling(target(option, of: place), in: comparing.wrappedValue,
                                                          primary: primaryTarget)
    }

    /// Older models stay out of the list until you search for them, unless one is in use or a favorite.
    private func filtered(_ place: Place, query: String) -> [String] {
        let current = place.provider
        let profile = profileOf(place)
        let all = app.menuModels(for: current, profileID: profile)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return all.filter { !app.workspace.hidesLegacyModel($0, for: current, chosen: isChosen(place) ? model : "") }
        }
        return all.filter {
            $0.lowercased().contains(needle) || app.modelMenuName($0, for: current, profileID: profile).lowercased().contains(needle)
        }
    }

    private func favoriteBinding(_ model: String, for current: RunProvider) -> Binding<Bool> {
        Binding(get: { ws.favoriteModels(for: current).contains(model) },
                set: { if $0 != ws.favoriteModels(for: current).contains(model) { ws.toggleFavoriteModel(model, for: current) } })
    }

    /// The search text as a model id of your own, when no listed model goes by that name.
    private func customModel(_ place: Place, query: String) -> String? {
        guard let id = ModelPreferences.customID(query),
              !app.menuModels(for: place.provider, profileID: profileOf(place))
                .contains(where: { app.workspace.sameModel($0, id, for: place.provider) }) else { return nil }
        return id
    }
}

/// Build/Plan control: not a menu but one button that switches between the two.
struct ModeToggle: View {
    @Binding var mode: ExecutionMode

    var body: some View {
        Button {
            mode = mode == .plan ? .agent : .plan
        } label: {
            ComposerPill(symbol: mode == .plan ? "list.bullet.clipboard" : "sparkles", dot: nil, text: mode.label,
                         tint: mode == .plan ? NookTheme.iris : nil, showsChevron: false)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(mode.help + " · " + tr("compose.modeSwitch"))
    }
}

/// Branch picker: a search field over the branches, the chosen one faintly filled.
struct BranchPicker: View {
    let branches: [String]
    let selected: String
    let choose: (String) -> Void
    @State private var query = ""

    var body: some View {
        DropdownSearch(placeholder: tr("compose.searchBranches"), text: $query)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = needle.isEmpty ? branches : branches.filter { $0.lowercased().contains(needle) }
        DropdownList(emptyNote: shown.isEmpty ? tr("compose.noBranches") : nil) {
            ForEach(shown, id: \.self) { branch in
                DropdownRow(symbol: "arrow.triangle.branch", title: branch, chosen: branch == selected) { choose(branch) }
            }
        }
    }
}

extension PermissionPolicy {
    /// The symbol shown for an access level.
    var symbol: String {
        switch self {
        case .ask: return "lock"
        case .acceptEdits: return "pencil"
        case .bypass: return "lock.open"
        }
    }
}
