import SwiftUI

/// Pull requests picked with ⇧- or ⌘-click on their rows, on the Pull requests page and in the side panel alike. Each
/// click adds or removes one row (no ranges: the rows you want are rarely next to each other). The bar under the list
/// (`PullRequestSelectionBar`) merges or closes them together after one confirmation.
@MainActor
final class PullRequestSelection: ObservableObject {
    static let shared = PullRequestSelection()

    /// In the order picked, each with the account it is read with.
    @Published private(set) var picked: [PullRequestOpenRequest] = []

    private init() {}

    var isEmpty: Bool { picked.isEmpty }

    func contains(_ id: String) -> Bool { picked.contains { $0.item.id == id } }

    func toggle(_ item: PullRequestItem, account: String) {
        if let index = picked.firstIndex(where: { $0.item.id == item.id }) {
            picked.remove(at: index)
        } else {
            picked.append(PullRequestOpenRequest(account: account, item: item))
        }
    }

    /// Everything shown; when all of it is picked already, nothing.
    func toggleAll(_ shown: [PullRequestOpenRequest]) {
        let ids = Set(shown.map(\.item.id))
        picked = !ids.isEmpty && ids.isSubset(of: Set(picked.map(\.item.id))) ? [] : shown
    }

    func clear() { picked = [] }

    /// Whether a click on a row picks it instead of opening it: ⇧ or ⌘ held.
    static func picks() -> Bool {
        let keys = SelectionClick.modifiers()
        return keys.command || keys.shift
    }
}

/// The ring around a picked pull request's row. Its own view, so a pick redraws the rings and not every row.
struct PullRequestSelectionRing: View {
    let id: String
    @ObservedObject private var selection = PullRequestSelection.shared

    var body: some View {
        NookTheme.shape(NookTheme.Radius.control)
            .strokeBorder(NookTheme.iris.opacity(selection.contains(id) ? 0.55 : 0))
            .allowsHitTesting(false)
    }
}

/// The bar under a list of pull requests while some are picked: how many, select all, done, and Merge and Close. Both
/// ask first in the bar ("Merge 2 pull requests?"); the second click sends them. Merges queue up and go one at a time
/// (`PullRequestQuickMerges`), each checked against what the one before changed.
struct PullRequestSelectionBar: View {
    /// The pull requests the list shows now, in its order, for select all.
    let shown: [PullRequestOpenRequest]
    /// Room around the bar, only while it shows.
    var inset: CGFloat = 0
    @ObservedObject private var selection = PullRequestSelection.shared

    var body: some View {
        if !selection.isEmpty {
            let picked = selection.picked
            let ids = Set(picked.map(\.item.id))
            let mergeable = picked.filter { PullRequestQuickAction.actions(for: $0.item).contains(.merge) }
            let closable = picked.filter { PullRequestQuickAction.actions(for: $0.item).contains(.close) }
            SelectionBar(count: picked.count,
                         allSelected: !shown.isEmpty && Set(shown.map(\.item.id)).isSubset(of: ids),
                         actions: [
                             SelectionAction(symbol: PullRequestIcon.symbol(.merged), label: tr("agents.pulls.quick.merge"),
                                             enabled: !mergeable.isEmpty,
                                             confirm: tr("agents.pulls.select.mergeConfirm", mergeable.count)) {
                                 merge(mergeable)
                             },
                             SelectionAction(symbol: PullRequestIcon.symbol(.closed), label: tr("agents.pulls.quick.close"),
                                             destructive: true, enabled: !closable.isEmpty,
                                             confirm: tr("agents.pulls.sweep.confirm", closable.count)) {
                                 close(closable)
                             },
                         ],
                         toggleAll: { selection.toggleAll(shown) },
                         done: { withAnimation(NookTheme.reveal) { selection.clear() } })
                .padding([.horizontal, .bottom], inset)
        }
    }

    private func merge(_ requests: [PullRequestOpenRequest]) {
        for request in requests {
            PullRequestQuickMerges.shared.add(request.item, accountID: request.account, app: AppModel.shared)
        }
        withAnimation(NookTheme.reveal) { selection.clear() }
    }

    private func close(_ requests: [PullRequestOpenRequest]) {
        withAnimation(NookTheme.reveal) { selection.clear() }
        Task { await PullRequestCloseSweep.close(requests, app: AppModel.shared) }
    }
}
