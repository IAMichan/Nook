import SwiftUI

// T3Code's composer dropdowns in Nook: the quiet pill as trigger, and instead of a system menu a dark panel with rows.
// A section header, rows with an icon or logo, a title and a description, a faint fill on the chosen row (no check
// mark), disabled rows that say why, and a search field for long lists. The model picker has T3Code's layout: the
// agents in a narrow rail on the left, their models with a search field on the right.

/// A composer choice that opens a T3Code-style panel under its pill.
struct ComposerDropdown<Trigger: View, Content: View>: View {
    var width: CGFloat = 264
    @ViewBuilder let trigger: () -> Trigger
    @ViewBuilder let content: () -> Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { trigger() }
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(4)
                    .frame(width: width, alignment: .leading)
                    .background(DropdownStyle.panel)
                    .environment(\.closeDropdown, { open = false })
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
            .font(NookTheme.font(11, .medium))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin line between groups.
struct DropdownDivider: View {
    var body: some View {
        Rectangle().fill(NookTheme.line2).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
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
    var disabledReason: String? = nil
    /// Keeps the panel open after the click (several choices in a row).
    var staysOpen = false
    let action: () -> Void
    @Environment(\.closeDropdown) private var close
    @State private var hovering = false

    var body: some View {
        Button {
            guard disabledReason == nil else { return }
            action()
            if !staysOpen { close() }
        } label: {
            HStack(alignment: detail == nil ? .center : .top, spacing: 8) {
                if let agent {
                    AgentMark(agent: agent, account: account, size: 15, ring: DropdownStyle.panel)
                } else if let brand {
                    BrandMark(logo: brand, size: 14)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tint ?? NookTheme.textSecondary)
                        .frame(width: 15)
                        .padding(.top, detail == nil ? 0 : 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(tint ?? NookTheme.paper)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(NookTheme.font(11))
                            .foregroundStyle(NookTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing).font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, detail == nil ? 5 : 6)
            .frame(minHeight: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(chosen ? DropdownStyle.chosen : (hovering && disabledReason == nil ? DropdownStyle.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabledReason == nil ? 1 : 0.64)
        .onHover { hovering = $0 }
        .help(disabledReason ?? "")
    }
}

/// The search field on top of a long list (models, branches), as in T3Code.
struct DropdownSearch: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(NookTheme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(NookTheme.font(12.5))
                .focused($focused)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(NookTheme.line2).frame(height: 1) }
        .onAppear { focused = true }
    }
}

/// T3Code's model picker: the connected agents in a narrow rail on the left, and on the right the chosen agent's
/// accounts and its models, with a search field. Picking an account or model keeps the panel open until you pick a model.
struct AgentModelPicker: View {
    @EnvironmentObject private var app: AppModel
    /// The agents you can pick from; one agent hides the rail (a running session keeps its agent).
    let providers: [RunProvider]
    let provider: RunProvider
    let profileID: String?
    let model: String
    var showsAccounts = false
    let choose: (RunProvider, String?, String?) -> Void
    @State private var shown: RunProvider?
    @State private var query = ""
    @Environment(\.closeDropdown) private var close

    private var current: RunProvider { shown ?? provider }

    var body: some View {
        HStack(spacing: 0) {
            if providers.count > 1 {
                VStack(spacing: 4) {
                    ForEach(providers) { option in
                        Button {
                            shown = option
                            query = ""
                        } label: {
                            AgentMark(agent: option.displayName, account: nil, size: 18, ring: DropdownStyle.panel)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(option == current ? DropdownStyle.chosen : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(option.displayName)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(width: 44)
                .background(NookTheme.paper.opacity(0.03))
                .overlay(alignment: .trailing) { Rectangle().fill(NookTheme.line2).frame(width: 1) }
            }
            VStack(alignment: .leading, spacing: 0) {
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let models = filtered
                        if models.isEmpty {
                            Text(tr("compose.noModels"))
                                .font(NookTheme.font(12))
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(10)
                        }
                        ForEach(models, id: \.self) { option in
                            let name = app.modelName(option, for: current)
                            DropdownRow(title: name, detail: option.isEmpty || name == option ? nil : option,
                                        chosen: current == provider && option == model) {
                                choose(current, current == provider ? nil : app.connectedProfiles(for: current).first?.id, option)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
            }
            .padding(.horizontal, 4)
        }
        .frame(maxHeight: 320)
    }

    private var filtered: [String] {
        let all = app.models(for: current)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(needle) || app.modelName($0, for: current).lowercased().contains(needle) }
    }
}

/// T3Code's Build/Plan control: not a menu but one button that switches between the two.
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

/// T3Code's branch picker: a search field over the branches, the chosen one faintly filled.
struct BranchPicker: View {
    let branches: [String]
    let selected: String
    let choose: (String) -> Void
    @State private var query = ""

    var body: some View {
        DropdownSearch(placeholder: tr("compose.searchBranches"), text: $query)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
                let shown = needle.isEmpty ? branches : branches.filter { $0.lowercased().contains(needle) }
                if shown.isEmpty {
                    Text(tr("compose.noBranches")).font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary).padding(10)
                }
                ForEach(shown, id: \.self) { branch in
                    DropdownRow(symbol: "arrow.triangle.branch", title: branch, chosen: branch == selected) { choose(branch) }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 260)
    }
}

extension PermissionPolicy {
    /// The symbol T3Code shows for an access level.
    var symbol: String {
        switch self {
        case .ask: return "lock"
        case .acceptEdits: return "pencil"
        case .bypass: return "lock.open"
        }
    }
}
