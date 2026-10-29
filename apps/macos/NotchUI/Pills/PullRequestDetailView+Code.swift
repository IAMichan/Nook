import AppKit
import SwiftUI

/// The Code tab: the changed files in reading order, each opening its diff.
extension PullRequestDetailView {
    // MARK: Files

    func files(_ detail: PullRequestDetail) -> some View {
        let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if detail.files.isEmpty {
                ListEmptyNote(tr("agents.pr.files.none"))
            } else {
                // How many are viewed shows in the tab bar. Lazy: a pull request can touch hundreds of files.
                LazyVStack(spacing: 0) {
                    ForEach(Array(orderedFiles(detail).enumerated()), id: \.element.id) { index, file in
                        if index > 0 { NookDivider(inset: NookTheme.Spacing.lg + 14 + NookTheme.Spacing.md) }
                        let status = viewed.status(file, in: key)
                        let seen = status == .viewed
                        HStack(spacing: 0) {
                            viewedButton(file, key: key, seen: seen)
                                .padding(.leading, NookTheme.Spacing.sm)
                            PullRequestHoverRow(action: { openFile = file.path }) {
                                HStack(spacing: NookTheme.Spacing.md) {
                                    fileGlyph(file.status)
                                    filePath(file.path)
                                    if status == .changed {
                                        Text(tr("agents.pr.files.changedSince"))
                                            .font(NookTheme.TextStyle.caption)
                                            .foregroundStyle(NookTheme.amber)
                                    } else if PullRequestFileOrder.kind(file.path) == .generated {
                                        Text(tr("agents.pr.files.generated"))
                                            .font(NookTheme.TextStyle.caption)
                                            .foregroundStyle(NookTheme.textTertiary)
                                    }
                                    Spacer(minLength: NookTheme.Spacing.sm)
                                    PullRequestLineCounts(additions: file.additions, deletions: file.deletions)
                                    PullRequestDiffStatBar(additions: file.additions, deletions: file.deletions)
                                }
                                .font(NookTheme.TextStyle.detail.monospacedDigit())
                            }
                            .opacity(seen ? 0.55 : 1)
                        }
                    }
                }
                .panelCard()
            }
        }
    }

    /// The files in reading order: each source file with its tests, then documentation, then generated files.
    func orderedFiles(_ detail: PullRequestDetail) -> [PullRequestFile] {
        let byPath = Dictionary(detail.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return PullRequestFileOrder.ordered(detail.files.map(\.path)).compactMap { byPath[$0] }
    }

    /// Ticks a file as viewed (or not), as on GitHub. The mark holds the file's revision, so a push that changes the file
    /// clears it again.
    func viewedButton(_ file: PullRequestFile, key: String, seen: Bool) -> some View {
        ToolbarIconButton(seen ? "checkmark.circle.fill" : "circle", tr(seen ? "agents.pr.files.unmarkViewed" : "agents.pr.files.markViewed")) {
            viewed.setViewed(!seen, file: file, in: key)
            viewed.save()
        }
        .help(tr(seen ? "agents.pr.files.unmarkViewed" : "agents.pr.files.markViewed"))
    }

    /// The file's name in full brightness, the folder it is in dimmed before it.
    func filePath(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        let folder = String(path.dropLast(name.count))
        return (Text(folder).foregroundStyle(NookTheme.textTertiary) + Text(name).foregroundStyle(NookTheme.paper))
            .font(NookTheme.TextStyle.code)
            .lineLimit(1)
            .truncationMode(.head)
            .help(path)
    }

    func fileGlyph(_ status: String) -> some View {
        let letter: String
        let color: Color
        switch status {
        case "added": letter = "A"; color = NookTheme.mint
        case "removed": letter = "D"; color = NookTheme.coral
        case "renamed", "copied": letter = "R"; color = NookTheme.violet
        default: letter = "M"; color = NookTheme.amber
        }
        return Text(letter).font(NookTheme.mono(11, .semibold)).foregroundStyle(color).frame(width: 14)
    }

    /// One file's diff under its header. The header is one line where it fits; beside the list (a narrow panel) the
    /// path keeps its own line and the counts and the buttons go under it, so the path is never squeezed to nothing.
    func fileDiff(_ file: PullRequestFile, detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NookTheme.Spacing.md) {
                    fileTitle(file)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    fileControls(file, detail: detail)
                }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    fileTitle(file)
                    HStack(spacing: NookTheme.Spacing.md) {
                        Spacer(minLength: 0)
                        fileControls(file, detail: detail)
                    }
                }
            }
            if let patch = file.patch, !patch.isEmpty {
                DiffText(text: patch)
                    .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
                    .id(file.path)
            } else {
                WSEmptyState(symbol: "doc.text.magnifyingglass", title: tr("agents.pr.files.noDiff"), message: tr("agents.pr.files.noDiffDetail"))
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Back to the list, the file's kind and its path (and the one it had before a rename).
    func fileTitle(_ file: PullRequestFile) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 24) { openFile = nil }
            fileGlyph(file.status)
            VStack(alignment: .leading, spacing: 1) {
                filePath(file.path)
                if let previous = file.previousPath {
                    Text(previous + " →").font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary).lineLimit(1).truncationMode(.head)
                }
            }
        }
    }

    /// The file's lines added and removed, its viewed mark, and where it is among the files with the buttons to the
    /// one before and after.
    func fileControls(_ file: PullRequestFile, detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            PullRequestLineCounts(additions: file.additions, deletions: file.deletions)
            let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
            viewedButton(file, key: key, seen: viewed.isViewed(file, in: key))
            let ordered = orderedFiles(detail)
            if let index = ordered.firstIndex(of: file) {
                Text("\(index + 1)/\(ordered.count)")
                    .font(NookTheme.TextStyle.detail.monospacedDigit())
                    .foregroundStyle(NookTheme.textTertiary)
                NookIconButton(systemName: "chevron.up", label: tr("agents.pr.files.previous"), size: 24) {
                    openFile = ordered[index - 1].path
                }
                .disabled(index == 0)
                .opacity(index == 0 ? 0.35 : 1)
                NookIconButton(systemName: "chevron.down", label: tr("agents.pr.files.next"), size: 24) {
                    openFile = ordered[index + 1].path
                }
                .disabled(index + 1 >= ordered.count)
                .opacity(index + 1 >= ordered.count ? 0.35 : 1)
            }
        }
        .fixedSize()
    }
}
