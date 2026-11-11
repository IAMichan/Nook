import SwiftUI

// The one model picker of Nook. The agents (a new session, a running one, a conversation continued in Nook) and Nook's
// own brain in the chat open the same `ModelPicker`: one width, a rail of places on the left (this Mac's local models
// first where the caller can run them, then choices that span every agent such as "Auto", then one logo per agent or
// service, once per account when it has several) with a "+" at its foot that opens Settings, and on the right the shown
// place's column: its name, the account, rows above the search ("send to several models"), the search field, the models
// (a star for favorites, "New", a model of your own typed in the search) and a link to Settings. Callers only hand over the places and the rows; the panel is drawn here.

enum ModelPickerStyle {
    static let width: CGFloat = 340
    /// The models scroll past this height, which keeps the whole panel on screen under a composer.
    static let listHeight: CGFloat = 240
    static let markSize: CGFloat = 18
    /// The column of reasoning levels beside the models.
    static let sideWidth: CGFloat = 170
}

/// The pill and panel of a model picker.
struct ModelPickerDropdown<Trigger: View, Content: View>: View {
    /// The picker also holds access and effort when it has a footer (`ModelPickerOptions`), so their keys open it.
    var holdsOptions = false
    /// A column beside the models makes the panel wider.
    var hasSideColumn = false
    @ViewBuilder let trigger: () -> Trigger
    @ViewBuilder let content: () -> Content

    var body: some View {
        // ⇧⌘M opens it (`modelPicker.toggle`).
        ComposerDropdown(width: ModelPickerStyle.width + (hasSideColumn ? ModelPickerStyle.sideWidth : 0), takesRoom: true, command: "modelPicker.toggle",
                         alsoOpenedBy: holdsOptions ? ["permissionPicker.toggle", "effortPicker.toggle"] : [],
                         trigger: trigger, content: content)
    }
}

/// A place in the model picker's rail: an agent or service (once per account when it has several), or this Mac.
struct ModelPickerPlace: Hashable {
    let id: String
    /// The agent or service's name: the column's title, and what picks its logo.
    let name: String
    /// The badge on the logo: whose account it runs under, or an API key.
    var account: AccountTag? = nil
    /// The line under the column's title: the account's name when an agent shows once per account.
    var detail: String? = nil
    /// This Mac's own models, drawn as a laptop instead of a logo.
    var isLocal = false
    /// A choice that spans every agent ("Auto"): drawn as this symbol in a group of its own, its column without a search.
    var symbol: String? = nil
}

/// One row in a place's column: a model, or an action between the models ("Use model …", "Fetch models").
struct ModelPickerItem: Identifiable {
    let id: String
    let title: String
    var brand: BrandLogo? = nil
    /// The badge on the model's logo: which account it belongs to, when the agent has several (as t3code's rows).
    var account: AccountTag? = nil
    /// Drawn instead of a logo, for an action.
    var symbol: String? = nil
    var detail: String? = nil
    var trailing: String? = nil
    var chosen = false
    /// Set when the model cannot be picked yet (it needs a newer agent).
    var disabledReason: String? = nil
    var staysOpen = false
    /// The star; nil leaves it out.
    var favorite: Binding<Bool>? = nil
    let pick: () -> Void
}

/// What one place's column lists.
struct ModelPickerList {
    var models: [ModelPickerItem]
    /// Rows after the models: a model of your own typed in the search, fetching the full list.
    var actions: [ModelPickerItem] = []
    /// Said when nothing is listed; by default "No models found".
    var emptyNote: String? = nil
}

/// The model picker: the places in a rail, the shown place's models in a column with a search.
struct ModelPicker<Above: View>: View {
    let places: [ModelPickerPlace]
    /// The place in use; the panel opens on it.
    let chosen: ModelPickerPlace
    /// What the "+" at the foot of the rail says it adds.
    let addHelp: String
    let settingsTitle: String
    /// Opens the Settings section where places and models are set up; the "+" and the link at the bottom both go there.
    let openSettings: () -> Void
    /// Rows above the search for a place ("send to several models").
    @ViewBuilder var above: (ModelPickerPlace) -> Above
    /// A footer under the rail and the column: what is chosen for the session beside the model (`ModelPickerOptions`).
    var footer: AnyView? = nil
    /// A column right of the models (the reasoning levels).
    var trailing: AnyView? = nil
    /// The rows for a place and the search text.
    let list: (ModelPickerPlace, String) -> ModelPickerList
    @State private var query = ""
    /// The row ↑/↓ are on; Return picks it.
    @State private var highlight = 0
    @Environment(\.closeDropdown) private var close

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                rail
                if let trailing {
                    NookDivider(vertical: true)
                    trailing.frame(width: ModelPickerStyle.sideWidth).frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let footer {
                NookDivider()
                footer
            }
        }
    }

    private var rail: some View {
        RailDropdown(groups: [places.filter(\.isLocal), places.filter { !$0.isLocal && $0.symbol != nil },
                              places.filter { !$0.isLocal && $0.symbol == nil }], chosen: chosen,
                     help: help(of:), onShow: { _ in query = ""; highlight = 0 },
                     icon: icon, footer: { ModelPickerAddButton(help: addHelp, add: openSettings) }) { place in
            column(place)
        }
    }

    @ViewBuilder
    private func icon(_ place: ModelPickerPlace) -> some View {
        if place.isLocal {
            Image(icon: "laptopcomputer")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(NookTheme.paper)
                .frame(width: ModelPickerStyle.markSize, height: ModelPickerStyle.markSize)
        } else if let symbol = place.symbol {
            NookSymbol(symbol, size: 13)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.paper)
                .frame(width: ModelPickerStyle.markSize, height: ModelPickerStyle.markSize)
        } else {
            AgentMark(agent: place.name, account: place.account, size: ModelPickerStyle.markSize, ring: DropdownStyle.panel)
        }
    }

    private func help(of place: ModelPickerPlace) -> String {
        guard !place.isLocal, let detail = place.detail else { return place.name }
        return "\(place.name) · \(detail)"
    }

    @ViewBuilder
    private func column(_ place: ModelPickerPlace) -> some View {
        let shown = list(place, query)
        DropdownHeader(title: place.name)
        if let detail = place.detail {
            Text(detail)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.bottom, NookTheme.Spacing.xs)
        }
        let rows = shown.models + shown.actions
        let current = ListHighlight.clamped(highlight, in: rows.map { $0.disabledReason == nil })
        above(place)
        if place.symbol == nil {
            DropdownSearch(placeholder: tr("compose.searchModels"), text: $query) {
                // Return picks the highlighted model (at first the first one that matches, or the model of your own
                // typed in the search).
                pick(rows, at: current)
            }
            .onChange(of: query) { _, _ in highlight = 0 }
        }
        DropdownList(maxHeight: ModelPickerStyle.listHeight,
                     emptyNote: rows.isEmpty ? shown.emptyNote ?? tr("compose.noModels") : nil,
                     scrollTarget: current.map { rows[$0].id }) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, item in
                DropdownRow(symbol: item.symbol, account: item.account, brand: item.brand, title: item.title, detail: item.detail,
                            trailing: item.trailing, chosen: item.chosen, disabledReason: item.disabledReason,
                            staysOpen: item.staysOpen, favorite: item.favorite, highlighted: offset == current,
                            action: item.pick)
            }
        }
        // ↑/↓ move the highlight over the rows that can be picked while the search keeps the keyboard; Return picks.
        .onWindowKeyDown { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            let enabled = rows.map { $0.disabledReason == nil }
            switch event.keyCode {
            case 125: highlight = ListHighlight.step(current, by: 1, in: enabled) ?? highlight
            case 126: highlight = ListHighlight.step(current, by: -1, in: enabled) ?? highlight
            case 36, 76: pick(rows, at: current)
            default: return false
            }
            return true
        }
        // ⌘1–⌘9 pick the nth model listed (`ModelPickerKeys`), also while the search has the keyboard.
        .keyCommands(numberKeys(shown.models), context: ["modelPickerOpen": true])
        DropdownDivider()
        DropdownRow(symbol: "gearshape", title: settingsTitle, action: openSettings)
    }

    private func numberKeys(_ models: [ModelPickerItem]) -> [String: () -> Bool] {
        let enabled = models.map { $0.disabledReason == nil }
        var out: [String: () -> Bool] = [:]
        for number in 1...ModelPickerKeys.count {
            out[ModelPickerKeys.command(number)] = {
                guard let index = ModelPickerKeys.row(number, enabled: enabled) else { return false }
                pick(models, at: index)
                return true
            }
        }
        return out
    }

    private func pick(_ rows: [ModelPickerItem], at index: Int?) {
        guard let index, rows.indices.contains(index), rows[index].disabledReason == nil else { return }
        rows[index].pick()
        if !rows[index].staysOpen { close() }
    }
}

extension ModelPicker where Above == EmptyView {
    init(places: [ModelPickerPlace], chosen: ModelPickerPlace, addHelp: String, settingsTitle: String,
         openSettings: @escaping () -> Void, footer: AnyView? = nil, trailing: AnyView? = nil,
         list: @escaping (ModelPickerPlace, String) -> ModelPickerList) {
        self.init(places: places, chosen: chosen, addHelp: addHelp, settingsTitle: settingsTitle,
                  openSettings: openSettings, above: { _ in EmptyView() }, footer: footer, trailing: trailing, list: list)
    }
}

/// The "+" at the foot of the rail.
private struct ModelPickerAddButton: View {
    let help: String
    let add: () -> Void
    @Environment(\.closeDropdown) private var close

    var body: some View {
        Button {
            close()
            add()
        } label: {
            Image(icon: "plus")
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Matches a model's names against the search text.
enum ModelSearch {
    static func matches(_ query: String, _ names: String...) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || names.contains { $0.lowercased().contains(needle) }
    }

    /// Whether a model's ID says more than its name, so it is worth a line under it: "claude-opus-5-5" only spells
    /// "Claude Opus 5.5" again, "claude-opus-4-1-20250805" adds a date.
    static func idAddsToName(_ id: String, _ name: String) -> Bool {
        func letters(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return !id.isEmpty && letters(id) != letters(name)
    }
}
