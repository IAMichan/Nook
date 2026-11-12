import SwiftUI
import AppKit

/// What the update button opens: what was merged since this build (or, in a downloaded build, the newer release) and the
/// button that installs it, the steps while it installs, the restart that waits for you (or, run from Xcode, the build there), why an install stopped, or what came
/// in with the update you just got.
struct UpdatePanel: View {
    @ObservedObject private var updater = AppUpdater.shared
    let close: () -> Void
    /// You asked to set uncommitted changes aside for this install and put them back after. Optional: without it the
    /// update leaves your changes in place and stashes only the files it also changes.
    @State private var stashConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            switch updater.phase {
            case .installing(let step): installing(step)
            case .readyToRestart: readyToRestart
            case .readyToBuildInXcode: readyToBuildInXcode
            case .failed(let failure): failed(failure)
            default:
                if let update = updater.available {
                    available(update)
                } else if let release = updater.releaseUpdate {
                    releaseAvailable(release)
                } else if let receipt = updater.receipt {
                    updated(receipt)
                } else {
                    upToDate
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(DropdownStyle.panel)
        .onAppear { updater.seen = true }
    }

    // MARK: Available

    private func available(_ update: AppUpdater.Available) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(symbol: "arrow.down.circle.fill", tint: NookTheme.paper, title: tr("update.title"),
                   detail: tr("update.subtitle", update.count, update.branch), refreshable: true)
            commitRange(from: updater.source?.shortCommit ?? "", to: update.shortTarget, update: update)
            changeList(update.changes, total: update.count, github: update.github)

            let preflight = update.preflight
            if update.checkout.atTarget {
                note(tr("update.atTarget"), symbol: "info.circle", tint: NookTheme.textSecondary)
            }
            switch preflight {
            case .blocked(let blocker):
                note(UpdateText.blocker(blocker, branch: update.branch), symbol: "exclamationmark.triangle.fill", tint: NookTheme.amber)
            case .hasChanges(let files, let overlapping):
                if overlapping.isEmpty {
                    note(tr("update.warning.stash", files), symbol: "tray.and.arrow.down", tint: NookTheme.textSecondary)
                } else {
                    note(tr("update.warning.overlap", files, Self.fileList(overlapping)), symbol: "tray.and.arrow.down",
                         tint: NookTheme.amber)
                }
                Toggle(isOn: $stashConsent) {
                    Text(tr("update.stashConsent")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.paper)
                }
                .toggleStyle(.checkbox)
            case .ready:
                EmptyView()
            }
            if updater.runningSessions > 0 {
                note(tr("update.warning.sessions", updater.runningSessions), symbol: "pause.circle", tint: NookTheme.amber)
            }
            Text(tr(updater.fromXcode ? "update.how.xcode" : "update.how"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: NookTheme.Spacing.md) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("update.later"), action: close)
                if case .blocked = preflight {
                    SmallGhostButton(title: tr("update.checkAgain")) { updater.check() }
                } else {
                    SmallPrimaryButton(title: tr(updater.fromXcode ? "update.install.xcode" : "update.install"),
                                       systemName: "arrow.down.circle") {
                        updater.install(stash: stashConsent && preflight != .ready)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// "Localizable.xcstrings", "a.swift, b.swift and 2 more": the files a note names.
    private static func fileList(_ paths: [String]) -> String {
        let names = paths.prefix(3).map { ($0.hasSuffix("/") ? $0 : ($0 as NSString).lastPathComponent) }
        let list = names.joined(separator: ", ")
        return paths.count > 3 ? list + " " + tr("update.more", paths.count - 3) : list
    }

    private func commitRange(from: String, to: String, update: AppUpdater.Available) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(verbatim: from).foregroundStyle(NookTheme.textSecondary)
            Image(icon: "arrow.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
            Text(verbatim: to).foregroundStyle(NookTheme.paper)
            Spacer(minLength: 0)
            if let url = update.github?.compare(from, to) {
                webLink(tr("update.viewOnGitHub"), url: url)
            }
        }
        .font(NookTheme.mono(11.5))
    }

    /// A small "… ↗" link that opens a page in the browser.
    private func webLink(_ title: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(icon: "arrow.up.right").font(NookTheme.font(9, .semibold))
            }
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
    }

    // MARK: Available release (a downloaded build)

    private func releaseAvailable(_ release: ReleaseCandidate) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(symbol: "arrow.down.circle.fill", tint: NookTheme.paper, title: tr("update.title"),
                   detail: tr("update.release.subtitle", release.title), refreshable: true)
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(verbatim: updater.release.map { "\($0.version)" } ?? "").foregroundStyle(NookTheme.textSecondary)
                Image(icon: "arrow.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
                Text(verbatim: "\(release.version)").foregroundStyle(NookTheme.paper)
                Spacer(minLength: 0)
                if let page = release.page {
                    webLink(tr("update.release.notes"), url: page)
                }
            }
            .font(NookTheme.mono(11.5))
            if !release.changes.isEmpty {
                changeList(release.changes, total: release.changeCount,
                           github: updater.release.flatMap { GitHubRepository(remoteURL: "https://github.com/\($0.repository)") })
            }
            if updater.isTranslocated {
                note(tr("update.translocated.note"), symbol: "folder.badge.questionmark", tint: NookTheme.amber)
            } else if updater.runningSessions > 0 {
                note(tr("update.warning.sessions", updater.runningSessions), symbol: "pause.circle", tint: NookTheme.amber)
            }
            Text(tr("update.release.how"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NookTheme.Spacing.md) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("update.later"), action: close)
                if updater.isTranslocated {
                    if updater.moving { ProgressView().controlSize(.small) }
                    SmallPrimaryButton(title: tr("update.moveToApplications"), systemName: "folder") { updater.moveToApplications() }
                        .disabled(updater.moving)
                        .keyboardShortcut(.defaultAction)
                } else {
                    SmallPrimaryButton(title: tr("update.install"), systemName: "arrow.down.circle") { updater.install() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// The merged pull requests, newest first; a row opens its pull request on GitHub.
    private func changeList(_ changes: [IncomingChange], total: Int, github: GitHubRepository?) -> some View {
        let shown = Array(changes.prefix(8))
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            ForEach(shown) { change in
                ChangeRow(change: change, url: change.pullRequest.flatMap { github?.pullRequest($0) })
            }
            if total > shown.count {
                Text(tr("update.more", total - shown.count))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.horizontal, NookTheme.Spacing.md)
                    .padding(.top, NookTheme.Spacing.xxs)
            }
        }
        .padding(NookTheme.Spacing.xs)
        .panelCard()
    }

    // MARK: Installing

    private func installing(_ current: UpdateStep) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(symbol: nil, tint: NookTheme.iris, title: tr("update.installing.title"), detail: tr("update.keepWorking"))
            VStack(alignment: .leading, spacing: 7) {
                // From Xcode the update ends with the project generated; Xcode does the build. A downloaded build
                // downloads and checks instead of building.
                ForEach(updater.steps, id: \.self) { step in
                    stepRow(step, current: current)
                }
            }
            if current == .download, let fraction = updater.downloadProgress {
                HStack(spacing: NookTheme.Spacing.md) {
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(NookTheme.iris)
                    Text(verbatim: "\(Int(fraction * 100))%")
                        .font(NookTheme.TextStyle.detail)
                        .monospacedDigit()
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .padding(.leading, NookTheme.Spacing.xxl)
            }
            if current == .build {
                VStack(alignment: .leading, spacing: 3) {
                    if let activity = updater.activity {
                        ShimmerText(text: UpdateText.activity(activity))
                            .font(NookTheme.TextStyle.detail)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if updater.compiledFiles > 0 {
                        Text(tr("update.compiled", updater.compiledFiles))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .padding(.leading, NookTheme.Spacing.xxl)
            }
            HStack {
                if let started = updater.installStarted {
                    TimelineView(.nookTicks(every: 1)) { context in
                        Text(tr("update.elapsed", Self.duration(context.date.timeIntervalSince(started))))
                            .font(NookTheme.TextStyle.detail)
                            .monospacedDigit()
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                if order(current) < order(.install) {
                    SmallGhostButton(title: tr("update.cancel")) { updater.cancel() }
                }
            }
        }
    }

    /// Where a step comes in this install (the two kinds of install have their steps in another order).
    private func order(_ step: UpdateStep) -> Int { updater.steps.firstIndex(of: step) ?? step.rawValue }

    private func stepRow(_ step: UpdateStep, current: UpdateStep) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Group {
                if order(step) < order(current) {
                    Image(icon: "checkmark.circle.fill").foregroundStyle(NookTheme.mint)
                } else if step == current {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(icon: "circle").foregroundStyle(NookTheme.line2)
                }
            }
            .font(NookTheme.TextStyle.body)
            .frame(width: 16, height: 16)
            Text(UpdateText.step(step))
                .font(step == current ? NookTheme.TextStyle.strong : NookTheme.TextStyle.body)
                .foregroundStyle(order(step) <= order(current) ? NookTheme.paper : NookTheme.textTertiary)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Ready, failed, done

    private var readyToRestart: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(symbol: "arrow.clockwise.circle.fill", tint: NookTheme.paper, title: tr("update.ready.title"),
                   detail: tr("update.ready.detail", updater.runningSessions))
            HStack(spacing: NookTheme.Spacing.md) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("update.later"), action: close)
                SmallPrimaryButton(title: tr("update.restartNow"), systemName: "arrow.clockwise") { updater.restart() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var readyToBuildInXcode: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(symbol: "hammer.circle.fill", tint: NookTheme.paper, title: tr("update.xcode.title"),
                   detail: tr("update.xcode.detail"))
            if updater.runningSessions > 0 {
                note(tr("update.warning.sessions", updater.runningSessions), symbol: "pause.circle", tint: NookTheme.amber)
            }
            HStack(spacing: NookTheme.Spacing.md) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("update.later"), action: close)
                SmallPrimaryButton(title: tr("update.xcode.run"), systemName: "hammer") {
                    updater.buildInXcode()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ failure: UpdateFailure) -> some View {
        let branch = updater.available?.branch ?? "main"
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(symbol: "exclamationmark.triangle.fill", tint: failure.reason == .cancelled ? NookTheme.amber : NookTheme.coral,
                   title: tr("update.failed.title"), detail: tr("update.failed.step", UpdateText.step(failure.step)))
            Text(UpdateText.reason(failure.reason, branch: branch))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !failure.errors.isEmpty {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    ForEach(failure.errors, id: \.self) { error in
                        Text(verbatim: error)
                            .font(NookTheme.mono(11))
                            .foregroundStyle(NookTheme.coralSoft)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(NookTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: NookTheme.Radius.control)
                .textSelection(.enabled)
            }
            HStack(spacing: NookTheme.Spacing.md) {
                if let log = failure.logPath {
                    SmallGhostButton(title: tr("update.showLog")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)])
                    }
                }
                if !failure.errors.isEmpty {
                    CopyGhostButton(title: tr("update.copyErrors")) { failure.errors.joined(separator: "\n") }
                }
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("update.close")) {
                    updater.dismissFailure()
                    close()
                }
                if failure.reason == .notRestarted {
                    // The new build is already in place: trying again only needs the restart, not a new build.
                    SmallGhostButton(title: tr("update.forceRestart")) { updater.forceRestart() }
                    SmallPrimaryButton(title: tr("update.tryAgain"), systemName: "arrow.clockwise") { updater.restart() }
                        .keyboardShortcut(.defaultAction)
                } else if failure.reason == .translocated {
                    SmallPrimaryButton(title: tr("update.moveToApplications"), systemName: "folder") { updater.moveToApplications() }
                        .disabled(updater.moving)
                        .keyboardShortcut(.defaultAction)
                } else if updater.hasUpdate {
                    SmallPrimaryButton(title: tr("update.tryAgain"), systemName: "arrow.clockwise") {
                        updater.dismissFailure()
                    }
                }
            }
        }
    }

    private func updated(_ receipt: UpdateReceipt) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(symbol: "checkmark.circle.fill", tint: NookTheme.mint, title: tr("update.updated.title"),
                   detail: tr("update.updated.detail", receipt.changes.count, receipt.shortTarget))
            if !receipt.changes.isEmpty {
                changeList(receipt.changes, total: receipt.changes.count, github: nil)
            }
            HStack {
                Spacer(minLength: 0)
                SmallPrimaryButton(title: tr("update.close")) {
                    updater.dismissReceipt()
                    close()
                }
            }
        }
    }

    private var upToDate: some View {
        header(symbol: "checkmark.circle.fill", tint: NookTheme.mint, title: tr("update.settings.status.upToDate"),
               detail: updater.lastChecked.map { tr("update.settings.lastChecked", NookDates.ago($0)) } ?? "", refreshable: true)
    }

    // MARK: Pieces

    /// `refreshable` adds the button that fetches main again, for when the list misses what was merged just now.
    private func header(symbol: String?, tint: Color, title: String, detail: String, refreshable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let symbol {
                    Image(icon: symbol).font(NookTheme.font(20, .semibold)).foregroundStyle(tint)
                } else {
                    ProgressView().controlSize(.small).tint(tint)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title).font(NookTheme.TextStyle.title).foregroundStyle(NookTheme.paper)
                if !detail.isEmpty {
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if refreshable {
                Spacer(minLength: 0)
                if updater.checking {
                    ProgressView().controlSize(.mini).frame(width: 24, height: 24)
                } else {
                    ToolbarIconButton("arrow.clockwise", tr("update.refresh")) { updater.check() }
                }
            }
        }
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            Image(icon: symbol).font(NookTheme.font(12, .semibold)).foregroundStyle(tint).frame(width: 16)
            Text(text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(tint.opacity(0.08), stroke: tint.opacity(0.25), radius: NookTheme.Radius.control)
    }
}

/// One merged pull request (or commit) in the list: its number, title and who merged it.
private struct ChangeRow: View {
    let change: IncomingChange
    let url: URL?
    @State private var hovering = false

    var body: some View {
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                Text(verbatim: change.pullRequest.map { "#\($0)" } ?? change.shortSHA)
                    .font(NookTheme.mono(11, .medium))
                    .foregroundStyle(change.pullRequest == nil ? NookTheme.textTertiary : NookTheme.violet)
                    .frame(minWidth: 38, alignment: .leading)
                Text(change.title)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(NookDates.ago(change.date))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, 5)
            .roundedBackground(hovering && url != nil ? DropdownStyle.hover : .clear, radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .disabled(url == nil)
        .onHover { hovering = $0 }
        .help(change.title + " · " + change.author)
    }
}
