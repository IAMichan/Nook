import SwiftUI

// MARK: - One row for every connection
//
// Every connection is laid out the same way: the icon, the name (and a version), one
// line that starts with the state ("Connected · michan@…"), a dot only when something is wrong, and on the right a
// switch (switching off keeps it) and a "…" menu whose last item, after a line, removes it after asking. Managing
// happens in the row itself: a click opens it in place and shows what the sheet used to show, so the page stays the page.

/// Whether a sheet's content is shown inside a row instead of in its own window: then `SetupSheet` draws only its
/// content, and `SheetPart`s drop their card (the row is already one).
private struct SheetEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sheetEmbedded: Bool {
        get { self[SheetEmbeddedKey.self] }
        set { self[SheetEmbeddedKey.self] = newValue }
    }
}

/// Asking before a connection goes: what it forgets, and that switching it off keeps it.
struct ConnectionRemoval {
    let title: String
    let question: String
    let detail: String
    let action: () -> Void
}

struct ConnectionRow<Icon: View, Menu: View, Detail: View>: View {
    let title: String
    var version: String? = nil
    let status: ServiceStatus
    /// Replaces the state's own word ("Signed in as …", "3 accounts").
    var statusText: String? = nil
    /// What follows the state, after a "·": the account, the host, the error.
    var detail: String? = nil
    /// The switch: on uses it, off keeps it but leaves it alone. Nil for a connection that cannot be switched off.
    var isOn: Binding<Bool>? = nil
    var removal: ConnectionRemoval? = nil
    /// Opens the row by itself, for one just added or one a link points at.
    var startsOpen = false
    @ViewBuilder var icon: () -> Icon
    /// The items above the line of the "…" menu.
    @ViewBuilder var menu: () -> Menu
    /// What the row shows once opened; nothing to open when it is empty.
    @ViewBuilder var expanded: () -> Detail

    @State private var open = false
    @State private var confirmRemove = false
    @State private var hovering = false

    private var opens: Bool { Detail.self != EmptyView.self }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.md) {
                icon()
                    .frame(width: 28, height: 28)
                    .opacity(isOn?.wrappedValue == false ? 0.6 : 1)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(title).font(NookTheme.TextStyle.strong).lineLimit(1)
                        if let version {
                            Text(version)
                                .font(NookTheme.mono(11))
                                .foregroundStyle(NookTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: NookTheme.Spacing.xs) {
                        // A dot only when something needs you: a working connection says so in words alone.
                        if status.needsAttention {
                            Circle().fill(status.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        }
                        Text(subtitle)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(status.needsAttention ? status.color : NookTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .opacity(isOn?.wrappedValue == false ? 0.6 : 1)
                Spacer(minLength: NookTheme.Spacing.md)
                if let isOn {
                    Toggle("", isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(isOn.wrappedValue ? tr("connection.switchOff") : tr("connection.switchOn"))
                        .accessibilityLabel(tr("connection.use", title))
                }
                moreMenu
                // The chevron last: every row lines up, whether it opens or not.
                DisclosureChevron(open: open, size: 10, weight: .semibold)
                    .frame(width: 12)
                    .opacity(opens ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .nookClickable(opens)
            .onTapGesture { if opens { withAnimation(NookTheme.reveal) { open.toggle() } } }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(opens ? .isButton : [])
            if open {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    expanded()
                }
                .environment(\.sheetEmbedded, true)
                // Under the name, past the icon.
                .padding(.leading, 28 + NookTheme.Spacing.md)
                .padding(.bottom, NookTheme.Spacing.xs)
                .transition(.opacity)
            }
        }
        .onAppear { if startsOpen { open = true } }
        .confirmationDialog(removal?.question ?? "", isPresented: $confirmRemove, titleVisibility: .visible) {
            if let removal {
                Button(removal.title, role: .destructive, action: removal.action)
            }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: {
            if let removal { Text(removal.detail) }
        }
    }

    private var subtitle: String {
        let state = statusText ?? status.label
        guard let detail, !detail.isEmpty else { return state }
        return state + " · " + detail
    }

    @ViewBuilder
    private var moreMenu: some View {
        let hasItems = Menu.self != EmptyView.self || removal != nil || opens
        if hasItems {
            SwiftUI.Menu {
                if opens {
                    Button(open ? tr("connection.close") : tr("connection.manage")) {
                        withAnimation(NookTheme.reveal) { open.toggle() }
                    }
                }
                menu()
                if let removal {
                    Divider()
                    Button(removal.title + "…", role: .destructive) { confirmRemove = true }
                }
            } label: {
                Image(icon: "ellipsis")
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.nookBorderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("connection.more"))
            .accessibilityLabel(tr("connection.more"))
        } else {
            // The menu's place kept empty, so every row's switch lines up with the rows above and below it.
            Color.clear.frame(width: 24, height: 24)
        }
    }
}

extension ConnectionRow where Menu == EmptyView {
    init(title: String, version: String? = nil, status: ServiceStatus, statusText: String? = nil, detail: String? = nil,
         isOn: Binding<Bool>? = nil, removal: ConnectionRemoval? = nil, startsOpen: Bool = false,
         @ViewBuilder icon: @escaping () -> Icon, @ViewBuilder expanded: @escaping () -> Detail) {
        self.init(title: title, version: version, status: status, statusText: statusText, detail: detail, isOn: isOn,
                  removal: removal, startsOpen: startsOpen, icon: icon, menu: { EmptyView() }, expanded: expanded)
    }
}

extension ConnectionRow where Detail == EmptyView {
    init(title: String, version: String? = nil, status: ServiceStatus, statusText: String? = nil, detail: String? = nil,
         isOn: Binding<Bool>? = nil, removal: ConnectionRemoval? = nil,
         @ViewBuilder icon: @escaping () -> Icon, @ViewBuilder menu: @escaping () -> Menu) {
        self.init(title: title, version: version, status: status, statusText: statusText, detail: detail, isOn: isOn,
                  removal: removal, icon: icon, menu: menu, expanded: { EmptyView() })
    }
}

extension ServiceStatus {
    /// Something is wrong or waits on you: the row shows a dot and its line in the state's color.
    var needsAttention: Bool {
        switch self {
        case .expired, .unreachable: return true
        case .notLinked, .connecting, .connected, .off: return false
        }
    }
}

/// The header of a list of connections: the name, its ⓘ, and on the right the one way to add
/// another ("+ Add machine"), so adding is always in the same place.
struct ConnectionListHeader: View {
    let title: String
    var info: String? = nil
    var add: (title: String, action: () -> Void)? = nil
    /// The button's symbol: "+" to add, another for an action on the whole list ("Update all").
    var symbol = "plus"

    var body: some View {
        HStack {
            SettingsSectionTitle(title, info: info)
            Spacer()
            if let add {
                Button(action: add.action) {
                    ConnectionListAddLabel(title: add.title, symbol: symbol)
                }
                .buttonStyle(.nookBorderless)
            }
        }
    }
}

/// `ConnectionListHeader` for a list where adding starts with a choice (which agent, which kind of host): the same
/// "+ Add …" on the right, opening a menu of the choices.
struct ConnectionListMenuHeader<Items: View>: View {
    let title: String
    var info: String? = nil
    let add: String
    @ViewBuilder var items: () -> Items

    var body: some View {
        HStack {
            SettingsSectionTitle(title, info: info)
            Spacer()
            Menu {
                items()
            } label: {
                ConnectionListAddLabel(title: add, symbol: "plus")
            }
            .menuStyle(.nookBorderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// The "+ Add …" in a list's header, one look whether it is a button or opens a menu.
struct ConnectionListAddLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, icon: symbol)
            .font(NookTheme.TextStyle.control)
            .foregroundStyle(NookTheme.textStrong)
    }
}

/// An empty list: what would be here. The way to add the first one is the "+ Add …" in the list's header, never a
/// second button in here.
struct ConnectionListEmpty: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(title).font(NookTheme.TextStyle.strong)
            Text(detail)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, NookTheme.Spacing.xs)
    }
}
