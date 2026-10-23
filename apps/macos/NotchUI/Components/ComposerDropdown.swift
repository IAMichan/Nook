import SwiftUI

// Composer dropdowns in Nook: the quiet pill as trigger, and instead of a system menu a dark panel with rows.
// A section header, rows with an icon or logo, a title and a description, a faint fill on the chosen row (no check
// mark), disabled rows that say why, and a search field for long lists. The model pickers (agents, and Nook's own
// brain in the chat) share one split layout: a narrow rail of places on the left, their models on the right.

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
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(4)
                    .frame(width: width, alignment: .leading)
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
    /// A star at the end of the row (the model menus): filled while the choice is a favorite, nil for none.
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
                    Image(systemName: symbol)
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(tile)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                            .fill(tile.opacity(hovering ? 0.24 : 0.16)))
                } else if let symbol {
                    Image(systemName: symbol)
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
    var maxHeight: CGFloat
    let help: (Place) -> String
    /// Called when you switch to another place in the rail (to clear a search, say).
    let onShow: (Place) -> Void
    let icon: (Place) -> Icon
    /// Sits at the bottom of the rail (an "add" button).
    let footer: () -> Footer
    let detail: (Place) -> Detail
    private var hasFooter = true
    @State private var shown: Place?

    init(groups: [[Place]], chosen: Place, maxHeight: CGFloat = 320,
         help: @escaping (Place) -> String, onShow: @escaping (Place) -> Void,
         @ViewBuilder icon: @escaping (Place) -> Icon,
         @ViewBuilder footer: @escaping () -> Footer,
         @ViewBuilder detail: @escaping (Place) -> Detail) {
        self.groups = groups
        self.chosen = chosen
        self.maxHeight = maxHeight
        self.help = help
        self.onShow = onShow
        self.icon = icon
        self.footer = footer
        self.detail = detail
    }

    private var current: Place { shown ?? chosen }
    private var filledGroups: [[Place]] { groups.filter { !$0.isEmpty } }

    var body: some View {
        HStack(spacing: 0) {
            if hasFooter || filledGroups.joined().count > 1 { rail }
            VStack(alignment: .leading, spacing: 0) { detail(current) }
                .padding(.horizontal, 4)
        }
        .frame(maxHeight: maxHeight)
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
    init(groups: [[Place]], chosen: Place, maxHeight: CGFloat = 320,
         help: @escaping (Place) -> String, onShow: @escaping (Place) -> Void,
         @ViewBuilder icon: @escaping (Place) -> Icon,
         @ViewBuilder detail: @escaping (Place) -> Detail) {
        self.init(groups: groups, chosen: chosen, maxHeight: maxHeight, help: help, onShow: onShow,
                  icon: icon, footer: { EmptyView() }, detail: detail)
        hasFooter = false
    }
}

/// A scrolling list of choices under a header or search field, with a note when there is nothing to show.
struct DropdownList<Rows: View>: View {
    var maxHeight: CGFloat = 260
    /// Shown instead of rows (nothing matches, nothing installed).
    var emptyNote: String? = nil
    @ViewBuilder let rows: () -> Rows

    var body: some View {
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
        }
        .frame(maxHeight: maxHeight)
    }
}

/// Model picker: the connected agents in the rail on the left, and on the right the shown agent's accounts and its
/// models, with a search field. Picking an account or model keeps the panel open until you pick a model.
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
    let choose: (RunProvider, String?, String?) -> Void
    @State private var query = ""

    var body: some View {
        RailDropdown(groups: [providers], chosen: provider, help: { $0.displayName }, onShow: { _ in query = "" },
                     icon: { AgentMark(agent: $0.displayName, account: account(of: $0), size: 18, ring: DropdownStyle.panel) }) { current in
            models(of: current)
        }
    }

    /// The account an agent runs under from here: the chosen one for the agent in use, else the one picking it would take.
    private func account(of current: RunProvider) -> AccountKind? {
        let accounts = app.connectedProfiles(for: current)
        let profile = current == provider ? accounts.first(where: { $0.id == profileID }) ?? accounts.first : accounts.first
        return profile.map { AccountKind.of($0, app: app) }
    }

    @ViewBuilder
    private func models(of current: RunProvider) -> some View {
        let accounts = app.connectedProfiles(for: current)
        // A running session keeps its account: only a new session shows the choice.
        if providers.count > 1 || showsAccounts, accounts.count > 1 {
            DropdownHeader(title: current.displayName)
            ForEach(accounts) { account in
                DropdownRow(agent: current.displayName, account: AccountKind.of(account, app: app),
                            title: AccountLabel.line(account, app: app),
                            chosen: current == provider && account.id == profileID, staysOpen: true) {
                    choose(current, account.id, nil)
                }
            }
            DropdownDivider()
        }
        DropdownSearch(placeholder: tr("compose.searchModels"), text: $query)
        let shownModels = filtered(current)
        let custom = customModel(current)
        DropdownList(emptyNote: shownModels.isEmpty && custom == nil ? tr("compose.noModels") : nil) {
            ForEach(shownModels, id: \.self) { option in
                // A model that comes in thinking levels shows once; its level is picked with the effort control.
                let family = app.modelFamily(option, for: current)
                let name = app.modelMenuName(option, for: current)
                let choice = app.workspace.modelChoice(option, for: current)
                // A model that needs a newer agent says which update unlocks it, and cannot be picked until then.
                DropdownRow(title: name,
                            detail: app.modelUpdateNote(option, for: current)
                                ?? (family != nil || option.isEmpty || name == option ? nil : option),
                            trailing: choice?.isNew == true && choice?.needsUpdate == false ? tr("compose.modelNew") : nil,
                            chosen: current == provider
                                && (app.workspace.sameModel(option, model, for: current) || family?.contains(model) == true),
                            disabledReason: app.modelUpdateHelp(option, for: current),
                            favorite: option.isEmpty ? nil : favoriteBinding(option, for: current)) {
                    let picked = app.menuPick(option, keeping: current == provider ? model : "", for: current)
                    choose(current, current == provider ? nil : app.connectedProfiles(for: current).first?.id, picked)
                }
            }
            if let custom {
                DropdownRow(symbol: "plus", title: tr("compose.useModel", custom), detail: tr("compose.useModelDetail")) {
                    ws.rememberCustomModel(custom, for: current)
                    choose(current, current == provider ? nil : app.connectedProfiles(for: current).first?.id, custom)
                }
            }
        }
    }

    /// Older models stay out of the list until you search for them, unless one is in use or a favorite.
    private func filtered(_ current: RunProvider) -> [String] {
        let all = app.menuModels(for: current)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return all.filter { !app.workspace.hidesLegacyModel($0, for: current, chosen: current == provider ? model : "") }
        }
        return all.filter { $0.lowercased().contains(needle) || app.modelMenuName($0, for: current).lowercased().contains(needle) }
    }

    private func favoriteBinding(_ model: String, for current: RunProvider) -> Binding<Bool> {
        Binding(get: { ws.favoriteModels(for: current).contains(model) },
                set: { if $0 != ws.favoriteModels(for: current).contains(model) { ws.toggleFavoriteModel(model, for: current) } })
    }

    /// The search text as a model id of your own, when no listed model goes by that name.
    private func customModel(_ current: RunProvider) -> String? {
        guard let id = ModelPreferences.customID(query),
              !app.menuModels(for: current).contains(where: { app.workspace.sameModel($0, id, for: current) }) else { return nil }
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
