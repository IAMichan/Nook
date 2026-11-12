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

/// The bar under a list of pull requests while some are picked: how many and which, select all, done, and Close and
/// Merge (the main one). Each asks first: what will happen, to which pull requests, and which are left out and why (a
/// draft, a conflict, failing checks). Merges queue up and go one at a time (`PullRequestQuickMerges`), each checked
/// against what the one before changed.
struct PullRequestSelectionBar: View {
    /// The pull requests the list shows now, in its order, for select all.
    let shown: [PullRequestOpenRequest]
    /// Room around the bar, only while it shows.
    var inset: CGFloat = 0
    @ObservedObject private var selection = PullRequestSelection.shared
    /// Why they are closed, posted on each before it closes; optional.
    @State private var closeComment = ""

    var body: some View {
        if !selection.isEmpty {
            let picked = selection.picked
            let ids = Set(picked.map(\.item.id))
            let mergeable = picked.filter { PullRequestQuickAction.mergeBlocker($0.item) == nil }
            let skipped = picked.compactMap { request in
                PullRequestQuickAction.mergeBlocker(request.item).map { tr($0, "#\(request.item.number)") }
            }
            let closable = picked.filter { PullRequestQuickAction.actions(for: $0.item).contains(.close) }
            SelectionBar(count: picked.count,
                         allSelected: !shown.isEmpty && Set(shown.map(\.item.id)).isSubset(of: ids),
                         actions: [
                             SelectionAction(symbol: PullRequestIcon.symbol(.closed), label: tr("agents.pulls.quick.close"),
                                             destructive: true, enabled: !closable.isEmpty,
                                             confirm: Self.question(closable, one: "agents.pulls.select.closeConfirmOne", many: "agents.pulls.sweep.confirm"),
                                             confirmTitle: tr("agents.pulls.select.closeYes"),
                                             confirmDetail: Self.numbers(closable),
                                             count: closable.count,
                                             note: $closeComment, notePlaceholder: tr("agents.pulls.close.commentPlaceholder")) {
                                 close(closable)
                             },
                             SelectionAction(symbol: PullRequestIcon.symbol(.merged), label: tr("agents.pulls.quick.merge"),
                                             enabled: !mergeable.isEmpty,
                                             confirm: Self.question(mergeable, one: "agents.pulls.select.mergeConfirmOne", many: "agents.pulls.select.mergeConfirm"),
                                             confirmTitle: tr("agents.pulls.select.mergeYes"),
                                             confirmDetail: Self.mergeDetail(mergeable, skipped: skipped),
                                             count: mergeable.count, primary: true,
                                             leftOutHelp: skipped.joined(separator: "\n")) {
                                 merge(mergeable)
                             },
                         ],
                         detail: Self.detail(picked, skipped: skipped),
                         toggleAll: { selection.toggleAll(shown) },
                         done: { withAnimation(NookTheme.reveal) { selection.clear() } })
                .padding([.horizontal, .bottom], inset)
        }
    }

    /// "Merge #12?" for one, "Merge 3 pull requests?" for more.
    private static func question(_ requests: [PullRequestOpenRequest], one: String, many: String) -> String {
        requests.count == 1 ? tr(one, "#\(requests[0].item.number)") : tr(many, requests.count)
    }

    /// "#12 · #15 · #18", the first eight and how many more.
    static func numbers(_ requests: [PullRequestOpenRequest]) -> String {
        let shown = requests.prefix(8).map { "#\($0.item.number)" }
        let more = requests.count - shown.count
        return shown.joined(separator: " · ") + (more > 0 ? " " + tr("agents.pulls.select.more", more) : "")
    }

    /// Which are picked, and under them which merge leaves out and why, so "Merge (2 of 3)" never comes as a surprise.
    private static func detail(_ picked: [PullRequestOpenRequest], skipped: [String]) -> String {
        guard !skipped.isEmpty else { return numbers(picked) }
        return numbers(picked) + "\n" + tr("agents.pulls.select.skipped", skipped.joined(separator: "; "))
    }

    /// Which go, in what order, and which are left out and why.
    private static func mergeDetail(_ mergeable: [PullRequestOpenRequest], skipped: [String]) -> String {
        var lines = [tr("agents.pulls.select.mergeDetail", numbers(mergeable))]
        if !skipped.isEmpty { lines.append(tr("agents.pulls.select.skipped", skipped.joined(separator: "; "))) }
        return lines.joined(separator: "\n")
    }

    private func merge(_ requests: [PullRequestOpenRequest]) {
        for request in requests {
            PullRequestQuickMerges.shared.add(request.item, accountID: request.account, app: AppModel.shared)
        }
        withAnimation(NookTheme.reveal) { selection.clear() }
    }

    private func close(_ requests: [PullRequestOpenRequest]) {
        let comment = closeComment
        closeComment = ""
        withAnimation(NookTheme.reveal) { selection.clear() }
        Task { await PullRequestCloseSweep.close(requests, comment: comment, app: AppModel.shared) }
    }
}
