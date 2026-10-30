import SwiftUI

// The one model picker of Nook. The agents (a new session, a running one, a conversation continued in Nook) and Nook's
// own brain in the chat open the same panel: one width, a rail of places on the left with a "+" at its foot that opens
// Settings, and on the right a column with the place's name, an optional line on what it is, a search field, the models
// and a link to Settings. Only what a row says differs.

enum ModelPickerStyle {
    static let width: CGFloat = 340
    /// The models scroll past this height, which keeps the whole panel on screen under a composer.
    static let listHeight: CGFloat = 240
}

/// The pill and panel of a model picker.
struct ModelPickerDropdown<Trigger: View, Content: View>: View {
    @ViewBuilder let trigger: () -> Trigger
    @ViewBuilder let content: () -> Content

    var body: some View {
        ComposerDropdown(width: ModelPickerStyle.width, takesRoom: true, trigger: trigger, content: content)
    }
}

/// The split panel of a model picker: the places in a rail, and the shown place's column (a `ModelPickerColumn`).
struct ModelPickerPanel<Place: Hashable, Icon: View, Detail: View>: View {
    let groups: [[Place]]
    let chosen: Place
    let help: (Place) -> String
    /// What the "+" at the foot of the rail says it adds.
    let addHelp: String
    let add: () -> Void
    /// Called when you switch to another place in the rail (to clear a search, say).
    var onShow: (Place) -> Void = { _ in }
    @ViewBuilder let icon: (Place) -> Icon
    @ViewBuilder let detail: (Place) -> Detail
    @Environment(\.closeDropdown) private var close

    var body: some View {
        RailDropdown(groups: groups, chosen: chosen, help: help, onShow: onShow,
                     icon: icon, footer: { addButton }, detail: detail)
    }

    private var addButton: some View {
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
        .help(addHelp)
    }
}

/// One place's column in a model picker: its name, an optional line on what it is, rows above the search (accounts,
/// "send to several models"), the search field, the models and a link to Settings.
struct ModelPickerColumn<Above: View, Rows: View>: View {
    let title: String
    var detail: String? = nil
    @Binding var query: String
    var emptyNote: String? = nil
    let settingsTitle: String
    let openSettings: () -> Void
    @ViewBuilder var above: () -> Above
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        DropdownHeader(title: title)
        if let detail {
            Text(detail)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.bottom, NookTheme.Spacing.xs)
        }
        above()
        DropdownSearch(placeholder: tr("compose.searchModels"), text: $query)
        DropdownList(maxHeight: ModelPickerStyle.listHeight, emptyNote: emptyNote, rows: rows)
        DropdownDivider()
        DropdownRow(symbol: "gearshape", title: settingsTitle, action: openSettings)
    }
}

extension ModelPickerColumn where Above == EmptyView {
    init(title: String, detail: String? = nil, query: Binding<String>, emptyNote: String? = nil,
         settingsTitle: String, openSettings: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows) {
        self.init(title: title, detail: detail, query: query, emptyNote: emptyNote, settingsTitle: settingsTitle,
                  openSettings: openSettings, above: { EmptyView() }, rows: rows)
    }
}
