import SwiftUI

/// The Filters button next to the pull request search: a dark dropdown with the filter kinds on the left (each with its
/// current choice) and the choices of the kind you point at on the right, like a submenu. A badge on the button counts
/// the choices that differ from the default; the panel stays open so several filters can be set in a row.
struct PullRequestFilterMenu: View {
    @Binding var filter: PullRequestFilter
    /// The authors in the lists, for the Author choice.
    let authors: [String]
    @State private var kind: Kind = .state
    @State private var hovering = false

    enum Kind: CaseIterable, Identifiable {
        case state, involvement, author, draft, checks
        var id: Self { self }

        var title: String {
            switch self {
            case .state: return tr("agents.pulls.filter.state")
            case .involvement: return tr("agents.pulls.filter.involvement")
            case .author: return tr("agents.pulls.filter.author")
            case .draft: return tr("agents.pulls.filter.draft")
            case .checks: return tr("agents.pulls.filter.checks")
            }
        }

        var symbol: String {
            switch self {
            case .state: return "arrow.triangle.pull"
            case .involvement: return "person.2"
            case .author: return "person"
            case .draft: return "pencil.line"
            case .checks: return "checkmark.seal"
            }
        }
    }

    var body: some View {
        ComposerDropdown(width: 404) {
            trigger
        } content: {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([Kind.state, .involvement]) { kindRow($0) }
                    DropdownDivider()
                    ForEach([Kind.author, .draft, .checks]) { kindRow($0) }
                    if filter.activeCount > 0 {
                        DropdownDivider()
                        DropdownRow(symbol: "arrow.uturn.backward", title: tr("agents.pulls.filter.reset"), staysOpen: true) {
                            filter = PullRequestFilter(query: filter.query)
                        }
                    }
                }
                .frame(width: 200)
                Rectangle().fill(NookTheme.line2).frame(width: 1).padding(.horizontal, 4)
                VStack(alignment: .leading, spacing: 0) {
                    DropdownHeader(title: kind.title)
                    choices
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .help(tr("agents.pulls.filters"))
    }

    private var trigger: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease").font(NookTheme.font(11, .semibold))
            Text(tr("agents.pulls.filters")).font(NookTheme.font(12.5, .medium))
            if filter.activeCount > 0 {
                Text("\(filter.activeCount)")
                    .font(NookTheme.font(10.5, .semibold))
                    .foregroundStyle(NookTheme.ink)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Circle().fill(NookTheme.paper))
            }
        }
        .foregroundStyle(filter.activeCount > 0 || hovering ? NookTheme.paper : NookTheme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .cardBackground(hovering ? NookTheme.smoke : NookTheme.field, stroke: NookTheme.line2, radius: 9, style: .continuous)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func kindRow(_ row: Kind) -> some View {
        Button { kind = row } label: {
            HStack(spacing: 8) {
                Image(systemName: row.symbol)
                    .font(NookTheme.font(11.5, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 15)
                Text(row.title).font(NookTheme.font(12.5, .medium)).foregroundStyle(NookTheme.paper).lineLimit(1)
                Spacer(minLength: 6)
                Text(value(of: row))
                    .font(NookTheme.font(11))
                    .foregroundStyle(isDefault(row) ? NookTheme.textTertiary : NookTheme.paper)
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(row == kind ? DropdownStyle.chosen : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pointing at a kind shows its choices, like a submenu.
        .onHover { if $0 { kind = row } }
    }

    private func isDefault(_ row: Kind) -> Bool {
        switch row {
        case .state: return filter.state == .open
        case .involvement: return filter.scope == .all
        case .author: return filter.author == nil
        case .draft: return filter.draft == .all
        case .checks: return filter.status == .any
        }
    }

    private func value(of row: Kind) -> String {
        switch row {
        case .state: return tr("agents.pulls.state." + filter.state.rawValue)
        case .involvement: return tr("agents.pulls.scope." + filter.scope.rawValue)
        case .author: return filter.author.map { "@" + $0 } ?? tr("agents.pulls.author.anyone")
        case .draft: return tr("agents.pulls.draft." + filter.draft.rawValue)
        case .checks: return tr("agents.pulls.status." + filter.status.rawValue)
        }
    }

    @ViewBuilder
    private var choices: some View {
        switch kind {
        case .state:
            ForEach(PullRequestFilter.State.allCases) { state in
                FilterChoiceRow(symbol: Self.symbol(state), tint: Self.tint(state), title: tr("agents.pulls.state." + state.rawValue),
                                chosen: filter.state == state) { filter.state = state }
            }
        case .involvement:
            ForEach(PullRequestFilter.Scope.allCases) { scope in
                FilterChoiceRow(symbol: scope == .all ? "tray.full" : scope == .reviews ? "eye" : "person",
                                title: tr("agents.pulls.scope." + scope.rawValue), chosen: filter.scope == scope) { filter.scope = scope }
            }
        case .author:
            DropdownList(maxHeight: 220) {
                FilterChoiceRow(symbol: "person.2", title: tr("agents.pulls.author.anyone"), chosen: filter.author == nil) { filter.author = nil }
                ForEach(authors, id: \.self) { login in
                    FilterChoiceRow(symbol: "person.crop.circle", title: "@" + login, chosen: filter.author == login) { filter.author = login }
                }
            }
        case .draft:
            ForEach(PullRequestFilter.Draft.allCases) { draft in
                FilterChoiceRow(symbol: draft == .all ? "tray.full" : draft == .drafts ? "pencil.line" : "checkmark.circle",
                                title: tr("agents.pulls.draft." + draft.rawValue), chosen: filter.draft == draft) { filter.draft = draft }
            }
        case .checks:
            ForEach(PullRequestFilter.Status.allCases) { status in
                FilterChoiceRow(symbol: Self.symbol(status), tint: Self.tint(status), title: tr("agents.pulls.status." + status.rawValue),
                                chosen: filter.status == status) { filter.status = status }
            }
        }
    }

    private static func symbol(_ state: PullRequestFilter.State) -> String {
        switch state {
        case .all: return "square.stack"
        case .open: return "arrow.triangle.pull"
        case .closed: return "xmark.circle"
        case .merged: return "arrow.triangle.merge"
        }
    }

    private static func tint(_ state: PullRequestFilter.State) -> Color? {
        switch state {
        case .all: return nil
        case .open: return NookTheme.mint
        case .closed: return NookTheme.coralSoft
        case .merged: return NookTheme.violet
        }
    }

    private static func symbol(_ status: PullRequestFilter.Status) -> String {
        switch status {
        case .any: return "circle.dashed"
        case .failing: return "xmark.circle"
        case .pending: return "clock"
        case .passing: return "checkmark.circle"
        }
    }

    private static func tint(_ status: PullRequestFilter.Status) -> Color? {
        switch status {
        case .any: return nil
        case .failing: return NookTheme.coral
        case .pending: return NookTheme.amber
        case .passing: return NookTheme.mint
        }
    }
}

/// One choice in the right half of the Filters dropdown: a (tinted) symbol, its name, and a check mark on the chosen one.
private struct FilterChoiceRow: View {
    let symbol: String
    var tint: Color? = nil
    let title: String
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(NookTheme.font(11.5, .medium))
                    .foregroundStyle(tint ?? NookTheme.textSecondary)
                    .frame(width: 15)
                Text(title).font(NookTheme.font(12.5, .medium)).foregroundStyle(NookTheme.paper).lineLimit(1)
                Spacer(minLength: 6)
                if chosen {
                    Image(systemName: "checkmark").font(NookTheme.font(10.5, .semibold)).foregroundStyle(NookTheme.paper)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(chosen ? DropdownStyle.chosen : (hovering ? DropdownStyle.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
