import SwiftUI

/// The Filters button next to the pull request search: a dark dropdown with the filter kinds on the left
/// (each with its current choice) and the choices of the kind you point at on the right, like a submenu. State and
/// involvement first; then author (searchable, with how many pull requests each wrote), labels (several at once, each
/// with its color and count), drafts, the review decision and checks; then the repository. A badge on the button counts
/// the choices that differ from the default; the panel stays open so several filters can be set in a row. A qualifier
/// typed in the search (`label:bug`) shows here as the choice it makes.
struct PullRequestFilterMenu: View {
    @Binding var filter: PullRequestFilter
    /// The authors, labels and repositories in the lists, counted in the chosen state.
    let facets: PullRequestFacets
    /// The connected GitHub accounts, for the Account choice (shown with more than one).
    var accounts: [(id: String, name: String)] = []
    /// Whether organizations or repositories are watched, for the Watched choice.
    var watching = false
    @State private var kind: Kind = .state
    @State private var hovering = false
    @State private var authorSearch = ""

    enum Kind: CaseIterable, Identifiable {
        case state, involvement, author, labels, draft, review, checks, repository, account
        var id: Self { self }

        var title: String {
            switch self {
            case .state: return tr("agents.pulls.filter.state")
            case .involvement: return tr("agents.pulls.filter.involvement")
            case .author: return tr("agents.pulls.filter.author")
            case .labels: return tr("agents.pulls.filter.labels")
            case .draft: return tr("agents.pulls.filter.draft")
            case .review: return tr("agents.pulls.filter.review")
            case .checks: return tr("agents.pulls.filter.checks")
            case .repository: return tr("agents.pulls.filter.repository")
            case .account: return tr("agents.pulls.filter.account")
            }
        }

        var symbol: String {
            switch self {
            case .state: return "arrow.triangle.pull"
            case .involvement: return "person.2"
            case .author: return "person"
            case .labels: return "tag"
            case .draft: return "pencil.line"
            case .review: return "checkmark.bubble"
            case .checks: return "checkmark.seal"
            case .repository: return "folder"
            case .account: return "person.crop.circle"
            }
        }
    }

    /// The badge counts what the dropdown and the typed qualifiers narrow.
    private var count: Int {
        let typed = filter.parsed
        return filter.activeCount + typed.labels.count + typed.excludedLabels.count
            + [typed.author != nil && filter.author == nil, typed.draft != nil && filter.draft == .all,
               typed.review != nil && filter.review == .all, typed.checks != nil && filter.status == .any,
               typed.repo != nil && filter.repo == nil].filter { $0 }.count
    }

    var body: some View {
        ComposerDropdown(width: 420) {
            PullRequestToolbarButton(symbol: "line.3.horizontal.decrease", title: tr("agents.pulls.filters"),
                                     badge: count, active: count > 0)
        } content: {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([Kind.state, .involvement]) { kindRow($0) }
                    DropdownDivider()
                    ForEach([Kind.author, .labels, .draft, .review, .checks]) { kindRow($0) }
                    let showsRepos = facets.repos.count > 1 || filter.repo != nil
                    let showsAccounts = accounts.count > 1 || filter.account != nil
                    if showsRepos || showsAccounts {
                        DropdownDivider()
                        if showsRepos { kindRow(.repository) }
                        if showsAccounts { kindRow(.account) }
                    }
                    if filter.activeCount > 0 {
                        DropdownDivider()
                        DropdownRow(symbol: "arrow.uturn.backward", title: tr("agents.pulls.filter.reset"), staysOpen: true) {
                            filter = PullRequestFilter(query: filter.query)
                        }
                    }
                }
                .frame(width: 204)
                NookDivider(vertical: true).padding(.horizontal, NookTheme.Spacing.xs)
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

    private func kindRow(_ row: Kind) -> some View {
        Button { kind = row } label: {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(systemName: row.symbol)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 15)
                Text(row.title).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1)
                Spacer(minLength: 6)
                Text(value(of: row))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(isDefault(row) ? NookTheme.textTertiary : NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
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
        case .author: return filter.effectiveAuthor == nil
        case .labels: return filter.labels.isEmpty && filter.parsed.labels.isEmpty && filter.parsed.excludedLabels.isEmpty
        case .draft: return filter.effectiveDraft == .all
        case .review: return filter.effectiveReview == .all
        case .checks: return filter.effectiveStatus == .any
        case .repository: return filter.effectiveRepo == nil
        case .account: return filter.account == nil
        }
    }

    private func value(of row: Kind) -> String {
        switch row {
        case .state: return tr("agents.pulls.state." + filter.state.rawValue)
        case .involvement: return tr("agents.pulls.scope." + filter.scope.rawValue)
        case .author: return filter.effectiveAuthor.map { "@" + $0 } ?? tr("agents.pulls.author.anyone")
        case .labels:
            let typed = filter.parsed.labels.count + filter.parsed.excludedLabels.count
            let chosen = filter.labels.count + typed
            if chosen == 0 { return tr("agents.pulls.labels.any") }
            return chosen == 1 && typed == 0 ? filter.labels[0] : tr("agents.pulls.labels.selected", chosen)
        case .draft: return tr("agents.pulls.draft." + filter.effectiveDraft.rawValue)
        case .review: return tr("agents.pulls.review." + filter.effectiveReview.rawValue)
        case .checks: return tr("agents.pulls.status." + filter.effectiveStatus.rawValue)
        case .repository: return filter.effectiveRepo ?? tr("agents.pulls.repo.all")
        case .account: return accounts.first { $0.id == filter.account }?.name ?? filter.account ?? tr("agents.pulls.account.all")
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
            ForEach(PullRequestFilter.Scope.allCases.filter { $0 != .watched || watching || filter.scope == .watched }) { scope in
                FilterChoiceRow(symbol: Self.symbol(scope),
                                title: tr("agents.pulls.scope." + scope.rawValue), chosen: filter.scope == scope) { filter.scope = scope }
            }
        case .author:
            authorChoices
        case .labels:
            labelChoices
        case .draft:
            ForEach(PullRequestFilter.Draft.allCases) { draft in
                FilterChoiceRow(symbol: draft == .all ? "square.stack" : draft == .drafts ? "pencil.line" : "eye.slash",
                                title: tr("agents.pulls.draft." + draft.rawValue), chosen: filter.effectiveDraft == draft) {
                    filter = filter.settingDraft(draft)
                }
            }
        case .review:
            ForEach(PullRequestFilter.Review.allCases) { review in
                FilterChoiceRow(symbol: Self.symbol(review), tint: Self.tint(review), title: tr("agents.pulls.review." + review.rawValue),
                                chosen: filter.effectiveReview == review) { set(["review"]) { $0.review = review } }
            }
        case .checks:
            ForEach(PullRequestFilter.Status.allCases) { status in
                FilterChoiceRow(symbol: Self.symbol(status), tint: Self.tint(status), title: tr("agents.pulls.status." + status.rawValue),
                                chosen: filter.effectiveStatus == status) { set(["checks", "status"]) { $0.status = status } }
            }
        case .account:
            FilterChoiceRow(symbol: "square.stack", title: tr("agents.pulls.account.all"), chosen: filter.account == nil) { filter.account = nil }
            ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                FilterChoiceRow(symbol: "person.crop.circle", title: account.name, chosen: filter.account == account.id) {
                    filter.account = account.id
                }
            }
        case .repository:
            DropdownList(maxHeight: 240) {
                FilterChoiceRow(symbol: "square.stack", title: tr("agents.pulls.repo.all"), chosen: filter.effectiveRepo == nil) { set(["repo"]) { $0.repo = nil } }
                ForEach(facets.repos) { repo in
                    FilterChoiceRow(symbol: "folder", title: repo.name, trailing: "\(repo.count)",
                                    chosen: filter.effectiveRepo?.lowercased() == repo.id) { set(["repo"]) { $0.repo = repo.name } }
                }
            }
        }
    }

    /// Anyone, then the authors that match the search, the chosen one first; ten at most.
    private var authorChoices: some View {
        let needle = authorSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let chosen = filter.effectiveAuthor?.lowercased()
        let selected = facets.authors.first { $0.id == chosen }
        let rest = facets.authors.filter { $0.id != chosen && (needle.isEmpty || $0.id.contains(needle)) }
        let shown = Array(((selected.map { [$0] } ?? []) + rest).prefix(10))
        return VStack(alignment: .leading, spacing: 0) {
            DropdownSearch(placeholder: tr("agents.pulls.author.search"), text: $authorSearch)
            DropdownList(maxHeight: 240, emptyNote: shown.isEmpty && !needle.isEmpty ? tr("agents.pulls.author.none") : nil) {
                if needle.isEmpty {
                    FilterChoiceRow(symbol: "person.2", title: tr("agents.pulls.author.anyone"), chosen: chosen == nil) { set(["author"]) { $0.author = nil } }
                }
                ForEach(shown) { author in
                    FilterChoiceRow(avatar: author.name, title: author.name, trailing: "\(author.count)",
                                    chosen: author.id == chosen) { set(["author"]) { $0.author = author.name } }
                }
            }
        }
    }

    /// Every label in the lists, with its color and how many pull requests carry it; several can be on at once, and a
    /// pull request must carry each one that is on.
    private var labelChoices: some View {
        let picked = Set(filter.labels.map { $0.lowercased() })
        let known = Set(facets.labels.map(\.id))
        let missing = filter.labels.filter { !known.contains($0.lowercased()) }
            .map { PullRequestFacets.Entry(name: $0, count: 0, color: nil) }
        let rows = missing + facets.labels
        return DropdownList(maxHeight: 260, emptyNote: rows.isEmpty ? tr("agents.pulls.labels.none") : nil) {
            ForEach(rows) { label in
                FilterChoiceRow(labelDot: true, labelColor: label.color, title: label.name, trailing: label.count > 0 ? "\(label.count)" : nil,
                                chosen: picked.contains(label.id)) {
                    if picked.contains(label.id) {
                        filter.labels.removeAll { $0.lowercased() == label.id }
                    } else if filter.labels.count < 10 {
                        filter.labels.append(label.name)
                    }
                }
            }
        }
    }

    /// Makes a dropdown choice, taking the same qualifier out of the search so the choice is the one that counts.
    private func set(_ keys: Set<String>, _ change: (inout PullRequestFilter) -> Void) {
        var next = filter.clearingTyped(keys)
        change(&next)
        filter = next
    }

    private static func symbol(_ scope: PullRequestFilter.Scope) -> String {
        switch scope {
        case .all: return "square.stack"
        case .reviews: return "eye"
        case .mine: return "pencil.line"
        case .watched: return "binoculars"
        }
    }

    private static func symbol(_ state: PullRequestFilter.State) -> String {
        switch state {
        case .all: return "square.stack"
        case .open: return NookSymbol.open
        case .closed: return "xmark.circle"
        case .merged: return NookSymbol.merge
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

    private static func symbol(_ review: PullRequestFilter.Review) -> String {
        switch review {
        case .all: return "square.stack"
        case .approved: return "checkmark.circle"
        case .changesRequested: return "xmark.circle"
        case .required: return "circle.dashed"
        case .noReviews: return "circle.slash"
        }
    }

    private static func tint(_ review: PullRequestFilter.Review) -> Color? {
        switch review {
        case .approved: return NookTheme.mint
        case .changesRequested: return NookTheme.amber
        case .all, .required, .noReviews: return nil
        }
    }

    private static func symbol(_ status: PullRequestFilter.Status) -> String {
        switch status {
        case .any: return "square.stack"
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

/// The Sort button beside Filters: the orders of the rows, and how the list groups them.
struct PullRequestSortMenu: View {
    @Binding var sort: PullRequestSort
    @Binding var grouping: PullRequestGrouping

    var body: some View {
        ComposerDropdown(width: 236) {
            PullRequestToolbarButton(symbol: "arrow.up.arrow.down", title: tr("agents.pulls.filter.sort"), badge: 0, active: false)
        } content: {
            DropdownHeader(title: tr("agents.pulls.filter.sort"))
            ForEach(PullRequestSort.allCases) { option in
                FilterChoiceRow(symbol: Self.symbol(option), tint: option == .attention ? NookTheme.amber : nil,
                                title: tr("agents.pulls.sort." + option.rawValue), chosen: sort == option) { sort = option }
            }
            DropdownDivider()
            DropdownHeader(title: tr("agents.pulls.filter.grouping"))
            ForEach(PullRequestGrouping.allCases) { option in
                FilterChoiceRow(symbol: option == .involvement ? "person.2" : "folder",
                                title: tr("agents.pulls.grouping." + option.rawValue), chosen: grouping == option) { grouping = option }
            }
        }
        .help(tr("agents.pulls.sortHelp"))
    }

    private static func symbol(_ sort: PullRequestSort) -> String {
        switch sort {
        case .attention: return "eye"
        case .readiness: return "checklist"
        case .blockedOnMe: return "person.badge.clock"
        case .recent: return "clock"
        case .oldest: return "calendar"
        case .largest: return "arrow.up.left.and.arrow.down.right"
        case .smallest: return "arrow.down.right.and.arrow.up.left"
        }
    }
}

/// An outlined button in the list's toolbar (Sort, Filters): a symbol, a word, and a count of what is on.
struct PullRequestToolbarButton: View {
    let symbol: String
    let title: String
    var badge = 0
    var active = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(NookTheme.font(11, .semibold))
            Text(title).font(NookTheme.TextStyle.body)
            if badge > 0 {
                Text("\(badge)")
                    .font(NookTheme.TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 15)
                    .background(Capsule().fill(NookTheme.smoke))
            }
        }
        .foregroundStyle(active || hovering ? NookTheme.paper : NookTheme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .cardBackground(hovering ? NookTheme.smoke : NookTheme.field, stroke: NookTheme.line2, radius: NookTheme.Radius.control, style: .continuous)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// One choice in the right half of the Filters dropdown: a (tinted) symbol, an author's picture or a label's dot, its
/// name, a count, and a check mark on the chosen one.
private struct FilterChoiceRow: View {
    var symbol: String? = nil
    var tint: Color? = nil
    /// A login whose picture leads the row.
    var avatar: String? = nil
    /// Leads the row with a label's dot, in `labelColor`.
    var labelDot = false
    var labelColor: String? = nil
    let title: String
    var trailing: String? = nil
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                Group {
                    if let avatar {
                        GitHubAvatar(login: avatar, size: 15)
                    } else if labelDot {
                        LabelDot(color: labelColor, size: 8)
                    } else if let symbol {
                        NookSymbol(symbol, size: 13)
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(tint ?? NookTheme.textSecondary)
                    }
                }
                .frame(width: 15)
                Text(title).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing).font(NookTheme.TextStyle.detail).monospacedDigit().foregroundStyle(NookTheme.textTertiary)
                }
                if chosen {
                    Image(systemName: "checkmark").font(NookTheme.font(10.5, .semibold)).foregroundStyle(NookTheme.paper)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
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
