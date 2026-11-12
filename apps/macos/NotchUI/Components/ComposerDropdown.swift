import SwiftUI
import AppKit

// Composer dropdowns in Nook: the quiet pill as trigger, and instead of a system menu a dark panel with rows.
// A section header, rows with an icon or logo, a title and a description, a faint fill on the chosen row (no check
// mark), disabled rows that say why, and a search field for long lists. The model pickers (agents, and Nook's own
// brain in the chat) share one split layout: a narrow rail of places on the left, their models on the right (ModelPicker.swift).

/// A composer choice that opens a custom dropdown panel under its pill.
struct ComposerDropdown<Trigger: View, Content: View>: View {
    var width: CGFloat = 264
    /// The trigger is a logo pill that may show its text in the room a crowded composer row has left.
    var takesRoom = false
    /// The keybinding command that opens and closes it (the model picker's ⇧⌘M).
    var command: String? = nil
    /// More commands that open it too (the model picker also holds access and effort: ⇧⌘A and ⇧⌘E).
    var alsoOpenedBy: [String] = []
    /// Scrolls once the rows are taller than the room on screen (a long menu), instead of running off the screen.
    var scrolls = false
    @ViewBuilder let trigger: () -> Trigger
    @ViewBuilder let content: () -> Content
    @Environment(\.composerDensity) private var density
    @State private var open = false

    var body: some View {
        let flexible = takesRoom && density.logosTakeRoom
        Button { open.toggle() } label: { trigger() }
            .buttonStyle(.nookPlain)
            .fixedSize(horizontal: !flexible, vertical: true)
            .modifier(DropdownKeyCommand(command: command, others: alsoOpenedBy, open: $open))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                // The panel takes the height its rows ask for at this width, so wrapped text grows it instead of
                // being cut off, and it follows when a search or another place changes what it shows.
                panel
                    .padding(scrolls ? 0 : 4)
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(DropdownStyle.panel)
                    .environment(\.closeDropdown, { open = false })
                    // A panel is a window of its own: the composer below cannot draw tips into it.
                    .environment(\.composerTipsHosted, false)
            }
            // Ahead of the spacer, so the pill gets all the room left instead of half of it.
            .layoutPriority(flexible ? 1 : 0)
    }

    @ViewBuilder
    private var panel: some View {
        if scrolls {
            DropdownList(maxHeight: Self.scrollingHeight) { content() }
                .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    /// Most of the screen, so a popover above or below the trigger still fits.
    private static var scrollingHeight: CGFloat {
        max(320, ((NSScreen.main?.visibleFrame.height) ?? 800) * 0.6)
    }
}

/// The key that opens a dropdown, offered only by the dropdowns that have one.
private struct DropdownKeyCommand: ViewModifier {
    let command: String?
    var others: [String] = []
    @Binding var open: Bool

    private func handlers(_ command: String) -> [String: () -> Bool] {
        let toggle: () -> Bool = { open.toggle(); return true }
        return Dictionary(uniqueKeysWithValues: ([command] + others).map { ($0, toggle) })
    }

    func body(content: Content) -> some View {
        if let command {
            content.keyCommands(handlers(command), context: ["modelPickerOpen": open])
        } else {
            content
        }
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
    var account: AccountTag? = nil
    var brand: BrandLogo? = nil
    /// A project's own icon (Settings › Projects), drawn instead of the symbol.
    var projectIcon: ProjectIcon? = nil
    /// A service's logo (its website's icon, a connector's), drawn instead of the symbol; the symbol stays while it loads
    /// or when the site has none.
    var site: String? = nil
    let title: String
    var detail: String? = nil
    var trailing: String? = nil
    var chosen = false
    var tint: Color? = nil
    /// Draws the symbol in a small tile of this color instead of on its own (the chat composer's "+" menu).
    var tile: Color? = nil
    /// A small picture in place of the tile (the picture on the clipboard, in the chat composer's "+" menu).
    var thumbnail: NSImage? = nil
    var disabledReason: String? = nil
    /// Keeps the panel open after the click (several choices in a row).
    var staysOpen = false
    /// A star at the end of the row (models and project folders): filled while the choice is a favorite, nil for none.
    var favorite: Binding<Bool>? = nil
    /// The row the arrow keys are on (the model picker): lit as under the pointer.
    var highlighted = false
    /// A row that folds a group open and closed: a chevron at the end that points down while it is open.
    var expanded: Bool? = nil
    let action: () -> Void
    @Environment(\.closeDropdown) private var close
    @State private var hovering = false

    /// Drawn with a tile or a picture in front: a taller row with the text centred beside it.
    private var tiled: Bool { tile != nil || thumbnail != nil }

    var body: some View {
        Button {
            guard disabledReason == nil else { return }
            action()
            if !staysOpen { close() }
        } label: {
            HStack(alignment: detail == nil || tiled ? .center : .top, spacing: tiled ? NookTheme.Spacing.md : 8) {
                if let agent {
                    AgentMark(agent: agent, account: account, size: 15, ring: DropdownStyle.panel)
                } else if let brand {
                    // A model of an account that needs telling apart carries its badge, as on the agent's logo in the rail.
                    BrandMark(logo: brand, size: 14)
                        .accountBadge(account, size: 14, ring: DropdownStyle.panel)
                        .padding(.trailing, account == nil ? 0 : 3)
                } else if let projectIcon {
                    ProjectIconView(icon: projectIcon, size: 15)
                        .padding(.top, detail == nil ? 0 : 1)
                } else if let site {
                    SiteIcon(domain: site, fallback: symbol ?? "link", tint: tint ?? NookTheme.textSecondary, size: 15)
                        .padding(.top, detail == nil ? 0 : 1)
                } else if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 26, height: 26)
                        .roundedClip(NookTheme.Radius.control)
                        .roundedStroke(NookTheme.line2, radius: NookTheme.Radius.control)
                } else if let symbol, let tile {
                    NookSymbol(symbol, size: 13)
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(tile)
                        .frame(width: 26, height: 26)
                        .roundedBackground(tile.opacity(hovering ? 0.24 : 0.16), radius: NookTheme.Radius.control)
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
                if let expanded {
                    Image(icon: "chevron.right")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(.horizontal, tiled ? NookTheme.Spacing.sm : NookTheme.Spacing.md)
            .padding(.vertical, tiled ? NookTheme.Spacing.xs : (detail == nil ? NookTheme.Spacing.sm : NookTheme.Spacing.md))
            .frame(minHeight: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedBackground(chosen && !highlighted ? DropdownStyle.chosen : ((hovering || highlighted) && disabledReason == nil ? DropdownStyle.hover : .clear),
                               radius: NookTheme.Radius.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
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
                Image(icon: starred ? "star.fill" : "star")
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(starred ? NookTheme.paper : NookTheme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .padding(.trailing, NookTheme.Spacing.xs)
            .help(tr(starred ? "compose.favoriteRemove" : "compose.favoriteAdd"))
            .accessibilityLabel(tr(starred ? "compose.favoriteRemove" : "compose.favoriteAdd"))
        }
    }
}

/// The big choices on top of a dropdown (the chat composer's "+" panel): `DropdownTile`s in a grid of three columns.
struct DropdownTileGrid<Content: View>: View {
    var columns = 3
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NookTheme.Spacing.xs), count: columns),
                  spacing: NookTheme.Spacing.xs) {
            content()
        }
    }
}

/// One big choice in a `DropdownTileGrid`: its symbol in a tinted tile, the title under it. Closes the dropdown.
struct DropdownTile: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void
    @Environment(\.closeDropdown) private var close
    @State private var hovering = false

    var body: some View {
        Button {
            action()
            close()
        } label: {
            VStack(spacing: NookTheme.Spacing.sm) {
                NookSymbol(symbol, size: 16)
                    .font(NookTheme.font(16, .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .roundedBackground(tint.opacity(hovering ? 0.26 : 0.16), radius: NookTheme.Radius.card)
                    .scaleEffect(hovering ? 1.04 : 1)
                Text(title)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, NookTheme.Spacing.md)
            .padding(.bottom, NookTheme.Spacing.sm)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .roundedBackground(hovering ? DropdownStyle.hover : .clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityLabel(title)
    }
}

/// A quiet line at the foot of a dropdown: a tip on another way to do what the rows offer.
struct DropdownNote: View {
    var symbol: String? = nil
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            if let symbol {
                Image(icon: symbol)
                    .font(NookTheme.TextStyle.detail)
            }
            Text(text)
                .font(NookTheme.TextStyle.detail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.top, NookTheme.Spacing.xs)
        .padding(.bottom, NookTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The search field on top of a long list (models, branches).
struct DropdownSearch: View {
    let placeholder: String
    @Binding var text: String
    /// Return in the field: picks the first match.
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        NookSearchField(prompt: placeholder, text: $text, style: .inline, focus: $focused, onSubmit: onSubmit)
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
        // ⇧⌘↑ and ⇧⌘↓ show the place before or after the shown one (`ModelPickerKeys`); the panel is its own window, so
        // it says itself that the picker is open.
        .keyCommands([ModelPickerKeys.previousPlace: { step(-1) }, ModelPickerKeys.nextPlace: { step(1) }],
                     context: ["modelPickerOpen": true])
    }

    private func step(_ offset: Int) -> Bool {
        guard let place = ModelPickerKeys.step(from: current, by: offset, in: Array(filledGroups.joined())) else { return false }
        shown = place
        onShow(place)
        return true
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
                .roundedBackground(place == current ? DropdownStyle.chosen : .clear, radius: NookTheme.Radius.control)
                // Top corner: the bottom one holds the account badge.
                .overlay(alignment: .topTrailing) {
                    if place == chosen && place != current {
                        Circle().fill(NookTheme.paper.opacity(0.7)).frame(width: 4, height: 4).padding(4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
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
    /// The id of the row the arrow keys are on: kept in view.
    var scrollTarget: String? = nil
    @ViewBuilder let rows: () -> Rows
    @State private var contentHeight: CGFloat = 0

    /// About five rows stay visible when the panel runs out of room.
    private static var minVisible: CGFloat { 156 }

    var body: some View {
        let fitted = min(contentHeight, maxHeight)
        ScrollViewReader { proxy in
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
            .onChange(of: scrollTarget) { _, target in
                if let target { proxy.scrollTo(target) }
            }
        }
        .frame(minHeight: min(fitted, Self.minVisible), idealHeight: fitted, maxHeight: fitted)
    }
}

/// This Mac's own models as a place in front of the agents: what Nook's own brain can think with besides the agents.
struct ModelPickerLocal {
    let place: ModelPickerPlace
    /// A local model is in use: the panel opens here and no agent's model is marked.
    let chosen: Bool
    /// The rows for the search text.
    let list: (String) -> ModelPickerList
}

/// Model picker of the agents and of Nook's own brain: the connected agents in the rail, one logo per account when an
/// agent has several, and on the right the shown account's models, with a search field. The brain adds this Mac's
/// models in front (`local`); otherwise the two pickers are one and the same.
struct AgentModelPicker: View {
    @EnvironmentObject private var app: AppModel
    /// Favorites and typed models live here: a star redraws the menu at once.
    @ObservedObject private var ws = WorkspaceSettings.shared
    /// The agents you can pick from; one agent hides the rail (a running session keeps its agent).
    let providers: [RunProvider]
    let provider: RunProvider
    let profileID: String?
    let model: String
    /// Accounts get a logo of their own (a running session keeps its account).
    var showsAccounts = true
    /// This Mac's models in front of the agents (Nook's own brain); nil for an agent.
    var local: ModelPickerLocal? = nil
    /// "Auto" as a place of its own in the rail, above the agents: Nook picks one per turn (see `AutoModel`). Off for
    /// Nook's own brain.
    var offersAuto = true
    /// Access, effort, speed and delegation for the session, under the models (`ModelPickerOptions`); nil for Nook's brain.
    var footer: AnyView? = nil
    /// The reasoning column beside the models (`ModelPickerReasoning`).
    var trailing: AnyView? = nil
    let choose: (RunProvider, String?, String?) -> Void

    /// One logo in the rail: an agent, or one of its accounts when it has several to pick from.
    private struct Place: Hashable {
        let provider: RunProvider
        /// Nil when the agent shows once: it runs under the account in use, or else the preferred one.
        let profileID: String?

        var id: String { [provider.rawValue, profileID].compactMap { $0 }.joined(separator: "/") }
    }

    private var places: [Place] {
        providers.flatMap { current -> [Place] in
            let accounts = app.connectedProfiles(for: current)
            guard showsAccounts, accounts.count > 1 else { return [Place(provider: current, profileID: nil)] }
            return accounts.map { Place(provider: current, profileID: $0.id) }
        }
    }

    private var chosenPlace: Place {
        let accounts = app.connectedProfiles(for: provider)
        guard showsAccounts, accounts.count > 1 else { return Place(provider: provider, profileID: nil) }
        return Place(provider: provider, profileID: profileID ?? accounts.first?.id)
    }

    var body: some View {
        let shown = places
        let agentPlaces = shown.map(pickerPlace)
        let auto = showsAuto ? Self.autoPlace : nil
        let chosen = local.flatMap { $0.chosen || agentPlaces.isEmpty ? $0.place : nil }
            ?? (auto != nil && model == AutoModel.id ? auto : nil)
            ?? pickerPlace(chosenPlace)
        ModelPicker(places: (local.map { [$0.place] } ?? []) + (auto.map { [$0] } ?? []) + agentPlaces, chosen: chosen,
                    addHelp: tr("agents.picker.add"),
                    openSettings: { app.openSettings(section: .agents) }, footer: footer, trailing: trailing, list: { picked, query in
            if let local, picked.id == local.place.id { return local.list(query) }
            if picked == Self.autoPlace { return ModelPickerList(models: [autoRow()]) }
            return shown.first { $0.id == picked.id }.map { models(of: $0, query: query) } ?? ModelPickerList(models: [])
        })
        // The picker's content only exists while it is open: opening it looks for newer models.
        .onAppear { app.modelPickerOpened() }
    }

    private func pickerPlace(_ place: Place) -> ModelPickerPlace {
        ModelPickerPlace(id: place.id, name: place.provider.displayName, account: account(of: place), detail: accountLine(of: place))
    }

    private func isChosen(_ place: Place) -> Bool { local?.chosen != true && place == chosenPlace }

    /// The account a place runs under: its own, the chosen one for the agent in use, else the one picking it would take.
    private func profile(of place: Place) -> AgentProfile? {
        let accounts = app.connectedProfiles(for: place.provider)
        let id = place.profileID ?? (place.provider == provider ? profileID : nil)
        return accounts.first(where: { $0.id == id }) ?? accounts.first
    }

    private func account(of place: Place) -> AccountTag? {
        AccountTag.badge(profile(of: place), app: app)
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
        let options = filtered(current, query: query)
        // A model that needs a newer agent: the update that unlocks it is one click away (Settings asks first).
        if AgentUpdates.updatable(current.provider),
           let required = options.lazy.compactMap({ app.modelUpdateVersion($0, for: current.provider) }).first {
            actions.append(ModelPickerItem(id: "update:" + current.provider.rawValue,
                                           title: tr("agentUpdate.pickerTitle", current.provider.displayName),
                                           symbol: "arrow.down.circle", detail: tr("agentUpdate.pickerDetail", required)) {
                app.requestAgentUpdate([current.provider])
            })
        }
        return ModelPickerList(models: options.map { modelRow($0, of: current) }, actions: actions)
    }

    // MARK: Auto

    /// "Auto" sits in the rail next to the agents, not under one of them: it spans every agent and account.
    private static var autoPlace: ModelPickerPlace { ModelPickerPlace(id: AutoModel.id, name: tr("auto.model"), symbol: AutoModel.symbol) }

    /// Hidden for Nook's own brain.
    private var showsAuto: Bool { offersAuto && local == nil }

    /// "Auto": Nook picks the agent, account and model for each turn from every model allowed in Settings, by the task
    /// and the limits. Picking it starts from the agent and account in use.
    private func autoRow() -> ModelPickerItem {
        let reach = app.workspace.autoReach()
        return ModelPickerItem(id: AutoModel.id, title: tr("auto.model"), symbol: AutoModel.symbol,
                               detail: reach.models > 0 ? tr("auto.model.detail", reach.models, reach.agents) : tr("auto.model.none"),
                               chosen: model == AutoModel.id) {
            choose(provider, nil, AutoModel.id)
        }
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
        // A model that needs a newer agent says which update unlocks it, and cannot be picked until then.
        return ModelPickerItem(id: option,
                               title: name,
                               brand: BrandLogo.forName(option) ?? BrandLogo.forName(name) ?? BrandLogo.forName(current.displayName),
                               account: account(of: place),
                               detail: app.modelUpdateNote(option, for: current)
                                   ?? (family == nil && ModelSearch.idAddsToName(option, name) ? option : nil),
                               trailing: choice?.isNew == true && choice?.needsUpdate == false ? tr("compose.modelNew") : nil,
                               chosen: isChosen,
                               disabledReason: app.modelUpdateHelp(option, for: current),
                               favorite: favoriteBinding(option, for: current)) {
            let picked = app.menuPick(option, keeping: self.isChosen(place) ? model : "", for: current, profileID: profile)
            choose(current, pickedProfile(place), picked)
        }
    }

    /// Older models stay out of the list until you search for them, unless one is in use or a favorite. The agent's own
    /// default (the empty id) is not offered: the list names real models only.
    private func filtered(_ place: Place, query: String) -> [String] {
        let current = place.provider
        let profile = profileOf(place)
        let all = app.menuModels(for: current, profileID: profile).filter { !$0.isEmpty }
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

/// Build/Plan control: not a menu but one button that switches between the two. The agent decides on Plan itself; the
/// composers show this only while Plan is on, so the read-only mode stays in sight and can be switched off.
struct ModeToggle: View {
    @Binding var mode: ExecutionMode

    var body: some View {
        Button {
            mode = mode == .plan ? .agent : .plan
        } label: {
            ComposerPill(symbol: mode == .plan ? "list.bullet.clipboard" : "sparkles", dot: nil, text: mode.label,
                         tint: mode == .plan ? NookTheme.iris : nil, showsChevron: false)
        }
        .buttonStyle(.nookPlain)
        .fixedSize()
        .composerTip(mode.help + " · " + tr("compose.modeSwitch"))
    }
}

/// Branch picker: a search field over the branches, the chosen one faintly filled.
struct BranchPicker: View {
    let branches: [String]
    let selected: String
    let choose: (String) -> Void
    @State private var query = ""
    @Environment(\.closeDropdown) private var close

    private var matches: [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? branches : branches.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        DropdownSearch(placeholder: tr("compose.searchBranches"), text: $query) {
            // Return picks the first branch that matches.
            guard let first = matches.first else { return }
            choose(first)
            close()
        }
        let shown = matches
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
        case .auto: return "checkmark.shield"
        case .bypass: return "lock.open"
        }
    }
}
