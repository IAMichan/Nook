import SwiftUI

// The one model picker of Nook. The agents (a new session, a running one, a conversation continued in Nook) and Nook's
// own brain in the chat open the same `ModelPicker`: one width, a rail of places on the left (this Mac's local models
// first where the caller can run them, then one logo per agent or service, once per account when it has several) with a
// "+" at its foot that opens Settings, and on the right the shown place's column: its name, the account, rows above the
// search ("send to several models"), the search field, the models (a star for favorites, "New", a model of your own
// typed in the search) and a link to Settings. Callers only hand over the places and the rows; the panel is drawn here.

enum ModelPickerStyle {
    static let width: CGFloat = 340
    /// The models scroll past this height, which keeps the whole panel on screen under a composer.
    static let listHeight: CGFloat = 240
    static let markSize: CGFloat = 18
}

/// The pill and panel of a model picker.
struct ModelPickerDropdown<Trigger: View, Content: View>: View {
    @ViewBuilder let trigger: () -> Trigger
    @ViewBuilder let content: () -> Content

    var body: some View {
        ComposerDropdown(width: ModelPickerStyle.width, takesRoom: true, trigger: trigger, content: content)
    }
}

/// A place in the model picker's rail: an agent or service (once per account when it has several), or this Mac.
struct ModelPickerPlace: Hashable {
    let id: String
    /// The agent or service's name: the column's title, and what picks its logo.
    let name: String
    /// The badge on the logo: whose account it runs under, or an API key.
    var account: AccountKind? = nil
    /// The line under the column's title: the account's name when an agent shows once per account.
    var detail: String? = nil
    /// This Mac's own models, drawn as a laptop instead of a logo.
    var isLocal = false
}

/// One row in a place's column: a model, or an action between the models ("Use model …", "Fetch models").
struct ModelPickerItem: Identifiable {
    let id: String
    let title: String
    var brand: BrandLogo? = nil
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
    /// The rows for a place and the search text.
    let list: (ModelPickerPlace, String) -> ModelPickerList
    @State private var query = ""

    var body: some View {
        RailDropdown(groups: [places.filter(\.isLocal), places.filter { !$0.isLocal }], chosen: chosen,
                     help: help(of:), onShow: { _ in query = "" },
                     icon: icon, footer: { ModelPickerAddButton(help: addHelp, add: openSettings) }) { place in
            column(place)
        }
    }

    @ViewBuilder
    private func icon(_ place: ModelPickerPlace) -> some View {
        if place.isLocal {
            Image(systemName: "laptopcomputer")
                .font(NookTheme.font(13, .medium))
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
        above(place)
        DropdownSearch(placeholder: tr("compose.searchModels"), text: $query)
        DropdownList(maxHeight: ModelPickerStyle.listHeight,
                     emptyNote: shown.models.isEmpty && shown.actions.isEmpty ? shown.emptyNote ?? tr("compose.noModels") : nil) {
            ForEach(shown.models + shown.actions) { item in
                DropdownRow(symbol: item.symbol, brand: item.brand, title: item.title, detail: item.detail,
                            trailing: item.trailing, chosen: item.chosen, disabledReason: item.disabledReason,
                            staysOpen: item.staysOpen, favorite: item.favorite, action: item.pick)
            }
        }
        DropdownDivider()
        DropdownRow(symbol: "gearshape", title: settingsTitle, action: openSettings)
    }
}

extension ModelPicker where Above == EmptyView {
    init(places: [ModelPickerPlace], chosen: ModelPickerPlace, addHelp: String, settingsTitle: String,
         openSettings: @escaping () -> Void, list: @escaping (ModelPickerPlace, String) -> ModelPickerList) {
        self.init(places: places, chosen: chosen, addHelp: addHelp, settingsTitle: settingsTitle,
                  openSettings: openSettings, above: { _ in EmptyView() }, list: list)
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
            Image(systemName: "plus")
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
