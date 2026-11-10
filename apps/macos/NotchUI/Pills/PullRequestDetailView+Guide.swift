import AppKit
import SwiftUI

/// The Guide tab: a review guide written for the pull request, read in order.
extension PullRequestDetailView {
    // MARK: Review guide

    /// A tour of the pull request in reading order: what each part changes, the files with a
    /// note (a click opens the file's diff), what to look at closely, and the questions only a maintainer can answer.
    @ViewBuilder
    func reviewGuide(_ detail: PullRequestDetail) -> some View {
        let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if writingGuide {
                HStack(spacing: NookTheme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text(tr("agents.pr.guide.writing")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                }
                .padding(NookTheme.Spacing.lg)
            } else if let guide {
                if !guide.isCurrent(for: detail.headSHA) {
                    HStack(spacing: NookTheme.Spacing.md) {
                        Image(icon: "clock.arrow.circlepath").foregroundStyle(NookTheme.amber)
                        Text(tr("agents.pr.guide.stale")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                        Spacer(minLength: 6)
                        NookGhostButton(title: tr("agents.pr.guide.rewrite"), compact: true) { writeGuide(detail, key: key) }
                    }
                    .padding(NookTheme.Spacing.md)
                    .panelCard()
                }
                ForEach(Array(guide.stops.enumerated()), id: \.offset) { index, stop in
                    guideStop(index + 1, stop)
                }
                HStack {
                    Text(tr("agents.pr.guide.written", NookDates.ago(guide.written)))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                    Spacer()
                    if guide.isCurrent(for: detail.headSHA) {
                        SmallGhostButton(title: tr("agents.pr.guide.rewrite")) { writeGuide(detail, key: key) }
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    Text(tr("agents.pr.guide.intro")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if guideFailed {
                        Text(tr("agents.pr.guide.failed")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.coral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    NookPrimaryButton(title: tr("agents.pr.guide.write"), symbol: "map") { writeGuide(detail, key: key) }
                        .fixedSize()
                }
                .padding(NookTheme.Spacing.lg)
                .panelCard()
            }
        }
        .onAppear { if guide == nil { guide = PullRequestReviewGuides.load(key) } }
    }

    func guideStop(_ number: Int, _ stop: PullRequestReviewGuide.Stop) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                Text("\(number)").font(NookTheme.mono(11, .semibold)).foregroundStyle(NookTheme.textTertiary)
                Text(stop.title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Spacer(minLength: 6)
                switch stop.attention {
                case .close:
                    Label(tr("agents.pr.guide.close"), systemImage: "eye")
                        .font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.amber)
                case .skim:
                    Text(tr("agents.pr.guide.skim")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
                case .normal:
                    EmptyView()
                }
                if let sessionContext, let detail {
                    ToolbarIconButton("plus.bubble", tr("session.context.askStop"), height: 20, width: 20) {
                        ComposerInbox.shared.add(SessionPrompts.guideStop(detail.sessionRef, title: stop.title, summary: stop.summary,
                                                                          files: stop.files.map(\.path)), to: sessionContext)
                    }
                }
            }
            if !stop.summary.isEmpty {
                Text(stop.summary).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(stop.files, id: \.path) { file in
                    PullRequestHoverRow(action: {
                        withAnimation(NookTheme.reveal) {
                            if guideFiles.contains(file.path) { guideFiles.remove(file.path) } else { guideFiles.insert(file.path) }
                        }
                    }) {
                        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                            Image(icon: "chevron.right")
                                .font(NookTheme.font(8.5, .bold))
                                .foregroundStyle(NookTheme.textTertiary)
                                .rotationEffect(.degrees(guideFiles.contains(file.path) ? 90 : 0))
                            filePath(file.path)
                            if !file.note.isEmpty {
                                Text(file.note).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            ToolbarIconButton("arrow.up.right", tr("agents.pr.guide.openCode"), height: 20, width: 20) {
                                switchTo(.code)
                                openFile = file.path
                            }
                        }
                    }
                    if guideFiles.contains(file.path), let detail, let patch = detail.files.first(where: { $0.path == file.path })?.patch, !patch.isEmpty {
                        // Written here, these wait for the review like the Code tab's.
                        let scope = "pull \(detail.id)"
                        DiffText(text: patch, comments: actions.lineComments.filter { $0.review.path == file.path }.map(\.review),
                                 onRemoveComment: { id in actions.lineComments.removeAll { $0.id == id } }, stacked: true, path: file.path, scope: scope,
                                 onRowComment: detail.isOpen ? { row, first, text in
                                     if let pending = PullRequestPendingComment.make(row, from: first, text: text, path: file.path, scope: scope) {
                                         actions.lineComments.append(pending)
                                     }
                                 } : nil)
                            .equatable()
                            .roundedClip(NookTheme.Radius.control)
                    }
                }
            }
            ForEach(stop.questions, id: \.self) { question in
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Image(icon: "questionmark.circle").foregroundStyle(NookTheme.amber)
                    Text(question).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(NookTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    func writeGuide(_ detail: PullRequestDetail, key: String) {
        guard !writingGuide else { return }
        writingGuide = true
        guideFailed = false
        Task {
            let written = await app.workspace.writeReviewGuide(detail)
            if let written {
                PullRequestReviewGuides.save(written, for: key)
                guide = written
            } else {
                guideFailed = true
            }
            writingGuide = false
        }
    }
}
