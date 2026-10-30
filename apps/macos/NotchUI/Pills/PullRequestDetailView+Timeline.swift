import AppKit
import SwiftUI

/// The Timeline tab: everything that happened, oldest first, on one rail.
extension PullRequestDetailView {
    // MARK: Timeline

    /// The history as one rail, oldest first: who did what, with conversations as cards and commits in runs.
    func timeline(_ detail: PullRequestDetail, now: Date) -> some View {
        let oldestFirst = PullRequestTimelineEntry.entries(detail.events)
        let entries = newestFirst ? Array(oldestFirst.reversed()) : oldestFirst
        return LazyVStack(alignment: .leading, spacing: 0) {
            if let created = detail.created, !newestFirst {
                PullRequestTimelineRail(last: entries.isEmpty) {
                    PullRequestTimelineMarker(symbol: PullRequestIcon.symbol(.open), color: PullRequestIcon.tint(.open))
                } content: {
                    activityLine(author: detail.author, sentence: tr("agents.pr.timeline.opened"), date: created, now: now)
                }
            }
            if entries.isEmpty {
                ListEmptyNote(tr("agents.pr.conversation.none"))
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    timelineEntry(entry, detail: detail, now: now,
                                  last: index == entries.count - 1 && !(newestFirst && detail.created != nil))
                }
            }
            if newestFirst, let created = detail.created {
                PullRequestTimelineRail(last: true) {
                    PullRequestTimelineMarker(symbol: PullRequestIcon.symbol(.open), color: PullRequestIcon.tint(.open))
                } content: {
                    activityLine(author: detail.author, sentence: tr("agents.pr.timeline.opened"), date: created, now: now)
                }
            }
        }
    }

    @ViewBuilder
    func timelineEntry(_ entry: PullRequestTimelineEntry, detail: PullRequestDetail, now: Date, last: Bool) -> some View {
        switch entry {
        case .commits(let run):
            // Each commit its own entry with its author's picture, as on timeline.
            ForEach(Array(run.enumerated()), id: \.element.id) { index, event in
                PullRequestTimelineRail(last: last && index == run.count - 1) {
                    GitHubAvatar(login: event.author, size: 28)
                } content: {
                    commitEntry(event, detail: detail, now: now)
                }
            }
        case .event(let event):
            switch event.kind {
            case .activity(let type, let subject):
                let look = activityLook(type)
                PullRequestTimelineRail(last: last) {
                    PullRequestTimelineMarker(symbol: look.symbol, color: look.color)
                } content: {
                    activityLine(author: event.author,
                                 sentence: tr("agents.pr.timeline." + type.replacingOccurrences(of: "-", with: "_"), subject),
                                 date: event.date, now: now)
                }
            default:
                PullRequestTimelineRail(last: last) {
                    GitHubAvatar(login: event.author, size: 28)
                } content: {
                    PullRequestCommentCard(event: event, now: now, showsAvatar: false)
                }
            }
        }
    }

    /// "ada labeled bug", the time under it writes an event.
    func activityLine(author: String, sentence: String, date: Date?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            (Text(author + " ").font(NookTheme.font(12, .semibold)).foregroundStyle(NookTheme.paper)
                + Text(sentence).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let date { timeLabel(date, now: now) }
        }
        .padding(.vertical, NookTheme.Spacing.sm)
    }

    /// A commit: its message in bold, its short hash and when under it; a click opens it on GitHub.
    @ViewBuilder
    func commitEntry(_ event: PullRequestEvent, detail: PullRequestDetail, now: Date) -> some View {
        if case .commit(let sha) = event.kind {
            PullRequestCommitEntry(sha: sha, message: event.body,
                                   details: PullRequestCommit.detailsBySHA(detail.commits)[sha] ?? "",
                                   time: event.date.map { AgentFormat.short(now.timeIntervalSince($0)) },
                                   date: event.date) { openCommit(sha, detail: detail) }
        }
    }

    func openCommit(_ sha: String, detail: PullRequestDetail) {
        if let url = detail.url?.appendingPathComponent("commits/" + sha) { NSWorkspace.shared.open(url) }
    }

    func timeLabel(_ date: Date, now: Date) -> some View {
        Text(AgentFormat.short(now.timeIntervalSince(date)))
            .font(NookTheme.font(11))
            .foregroundStyle(NookTheme.textTertiary)
            .monospacedDigit()
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }

    func activityLook(_ type: String) -> (symbol: String, color: Color) {
        switch type {
        case "labeled", "unlabeled": return ("tag", NookTheme.textTertiary)
        case "assigned", "unassigned": return ("person", NookTheme.textTertiary)
        case "review_requested", "review_request_removed":
            return (PullRequestIcon.symbol(PullRequestIcon.Review.required), PullRequestIcon.tint(PullRequestIcon.Review.required))
        // An event shows the mark of the state it leads to.
        case "ready_for_review", "reopened": return (PullRequestIcon.symbol(.open), PullRequestIcon.tint(.open))
        case "renamed": return ("pencil", NookTheme.textTertiary)
        case "convert_to_draft": return (PullRequestIcon.symbol(.draft), PullRequestIcon.tint(.draft))
        case "head_ref_force_pushed": return ("arrow.up.circle", NookTheme.amber)
        case "head_ref_deleted", "head_ref_restored", "base_ref_changed": return ("arrow.triangle.branch", NookTheme.textTertiary)
        case "merged": return (PullRequestIcon.symbol(.merged), PullRequestIcon.tint(.merged))
        case "closed": return (PullRequestIcon.symbol(.closed), PullRequestIcon.tint(.closed))
        case "cross-referenced", "referenced": return ("link", NookTheme.textTertiary)
        case "milestoned", "demilestoned": return ("flag", NookTheme.textTertiary)
        case "auto_merge_enabled", "auto_merge_disabled": return ("bolt", NookTheme.textTertiary)
        case "review_dismissed":
            return (PullRequestIcon.symbol(PullRequestIcon.Review.dismissed), PullRequestIcon.tint(PullRequestIcon.Review.dismissed))
        default: return ("circle", NookTheme.textTertiary)
        }
    }
}
