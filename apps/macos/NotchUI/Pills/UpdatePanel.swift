import SwiftUI
import AppKit

/// What the update button opens: what was merged since this build and the button that installs it, the steps while it
/// installs, the restart that waits for you, why an install stopped, or what came in with the update you just got.
struct UpdatePanel: View {
    @ObservedObject private var updater = AppUpdater.shared
    let close: () -> Void
    /// You agreed to set uncommitted changes aside for this install.
    @State private var stashConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updater.phase {
            case .installing(let step): installing(step)
            case .readyToRestart: readyToRestart
            case .failed(let failure): failed(failure)
            default:
                if let update = updater.available {
                    available(update)
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
        VStack(alignment: .leading, spacing: 12) {
            header(symbol: "arrow.down.circle.fill", tint: NookTheme.mint, title: tr("update.title"),
                   detail: tr("update.subtitle", update.count, update.branch))
            commitRange(from: updater.source?.shortCommit ?? "", to: update.shortTarget, update: update)
            changeList(update.changes, total: update.count, github: update.github)

            let preflight = update.preflight
            if update.checkout.atTarget {
                note(tr("update.atTarget"), symbol: "info.circle", tint: NookTheme.textSecondary)
            }
            switch preflight {
            case .blocked(let blocker):
                note(UpdateText.blocker(blocker, branch: update.branch), symbol: "exclamationmark.triangle.fill", tint: NookTheme.amber)
            case .needsStash(let files):
                note(tr("update.warning.stash", files), symbol: "tray.and.arrow.down", tint: NookTheme.amber)
                Toggle(isOn: $stashConsent) {
                    Text(tr("update.stashConsent")).font(NookTheme.font(12)).foregroundStyle(NookTheme.paper)
                }
                .toggleStyle(.checkbox)
            case .ready:
                EmptyView()
            }
            if updater.runningSessions > 0 {
                note(tr("update.warning.sessions", updater.runningSessions), symbol: "pause.circle", tint: NookTheme.amber)
            }
            Text(tr("update.how"))
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("update.later"), action: close)
                if case .blocked = preflight {
                    SmallGhostButton(title: tr("update.checkAgain")) { updater.check() }
                } else {
                    let needsConsent = preflight != .ready && !stashConsent
                    SmallPrimaryButton(title: tr("update.install"), systemName: "arrow.down.circle") {
                        updater.install(stash: stashConsent)
                    }
                    .disabled(needsConsent)
                    .opacity(needsConsent ? 0.4 : 1)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func commitRange(from: String, to: String, update: AppUpdater.Available) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: from).foregroundStyle(NookTheme.textSecondary)
            Image(systemName: "arrow.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
            Text(verbatim: to).foregroundStyle(NookTheme.paper)
            Spacer(minLength: 0)
            if let url = update.github?.compare(from, to) {
                Button { NSWorkspace.shared.open(url) } label: {
                    HStack(spacing: 3) {
                        Text(tr("update.viewOnGitHub"))
                        Image(systemName: "arrow.up.right").font(NookTheme.font(9, .semibold))
                    }
                    .font(NookTheme.font(11.5, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(NookTheme.mono(11.5))
    }

    /// The merged pull requests, newest first; a row opens its pull request on GitHub.
    private func changeList(_ changes: [IncomingChange], total: Int, github: GitHubRepository?) -> some View {
        let shown = Array(changes.prefix(8))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { change in
                ChangeRow(change: change, url: change.pullRequest.flatMap { github?.pullRequest($0) })
            }
            if total > shown.count {
                Text(tr("update.more", total - shown.count))
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
        }
        .padding(4)
        .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: 10, style: .continuous)
    }

    // MARK: Installing

    private func installing(_ current: UpdateStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(symbol: nil, tint: NookTheme.iris, title: tr("update.installing.title"), detail: tr("update.keepWorking"))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(UpdateStep.allCases, id: \.self) { step in
                    stepRow(step, current: current)
                }
            }
            if current == .build {
                VStack(alignment: .leading, spacing: 3) {
                    if let activity = updater.activity {
                        ShimmerText(text: UpdateText.activity(activity))
                            .font(NookTheme.font(11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if updater.compiledFiles > 0 {
                        Text(tr("update.compiled", updater.compiledFiles))
                            .font(NookTheme.font(11))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .padding(.leading, 24)
            }
            HStack {
                if let started = updater.installStarted {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(tr("update.elapsed", Self.duration(context.date.timeIntervalSince(started))))
                            .font(NookTheme.font(11.5))
                            .monospacedDigit()
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                if current < .install {
                    SmallGhostButton(title: tr("update.cancel")) { updater.cancel() }
                }
            }
        }
    }

    private func stepRow(_ step: UpdateStep, current: UpdateStep) -> some View {
        HStack(spacing: 8) {
            Group {
                if step < current {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(NookTheme.mint)
                } else if step == current {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "circle").foregroundStyle(NookTheme.line2)
                }
            }
            .font(NookTheme.font(13))
            .frame(width: 16, height: 16)
            Text(UpdateText.step(step))
                .font(NookTheme.font(12.5, step == current ? .semibold : .regular))
                .foregroundStyle(step <= current ? NookTheme.paper : NookTheme.textTertiary)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Ready, failed, done

    private var readyToRestart: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(symbol: "arrow.clockwise.circle.fill", tint: NookTheme.mint, title: tr("update.ready.title"),
                   detail: tr("update.ready.detail", updater.runningSessions))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("update.later"), action: close)
                SmallPrimaryButton(title: tr("update.restartNow"), systemName: "arrow.clockwise") { updater.restart() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ failure: UpdateFailure) -> some View {
        let branch = updater.available?.branch ?? "main"
        return VStack(alignment: .leading, spacing: 12) {
            header(symbol: "exclamationmark.triangle.fill", tint: failure.reason == .cancelled ? NookTheme.amber : NookTheme.coral,
                   title: tr("update.failed.title"), detail: tr("update.failed.step", UpdateText.step(failure.step)))
            Text(UpdateText.reason(failure.reason, branch: branch))
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !failure.errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(failure.errors, id: \.self) { error in
                        Text(verbatim: error)
                            .font(NookTheme.mono(11))
                            .foregroundStyle(NookTheme.coralSoft)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: 8, style: .continuous)
                .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let log = failure.logPath {
                    SmallGhostButton(title: tr("update.showLog")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)])
                    }
                }
                if !failure.errors.isEmpty {
                    SmallGhostButton(title: tr("update.copyErrors")) { Pasteboard.copy(failure.errors.joined(separator: "\n")) }
                }
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("update.close")) {
                    updater.dismissFailure()
                    close()
                }
                if updater.available != nil {
                    SmallPrimaryButton(title: tr("update.tryAgain"), systemName: "arrow.clockwise") {
                        updater.dismissFailure()
                    }
                }
            }
        }
    }

    private func updated(_ receipt: UpdateReceipt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(symbol: "checkmark.circle.fill", tint: NookTheme.mint, title: tr("update.updated.title"),
                   detail: tr("update.updated.detail", receipt.changes.count, String(receipt.to.prefix(7))))
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
               detail: updater.lastChecked.map { tr("update.settings.lastChecked", NookDates.ago($0)) } ?? "")
    }

    // MARK: Pieces

    private func header(symbol: String?, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(NookTheme.font(20, .semibold)).foregroundStyle(tint)
                } else {
                    ProgressView().controlSize(.small).tint(tint)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NookTheme.font(14, .semibold)).foregroundStyle(NookTheme.paper)
                if !detail.isEmpty {
                    Text(detail)
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(NookTheme.font(12, .semibold)).foregroundStyle(tint).frame(width: 16)
            Text(text)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(tint.opacity(0.08), stroke: tint.opacity(0.25), radius: 8, style: .continuous)
    }
}

/// One merged pull request (or commit) in the list: its number, title and who merged it.
private struct ChangeRow: View {
    let change: IncomingChange
    let url: URL?
    @State private var hovering = false

    var body: some View {
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: change.pullRequest.map { "#\($0)" } ?? change.shortSHA)
                    .font(NookTheme.mono(11, .medium))
                    .foregroundStyle(change.pullRequest == nil ? NookTheme.textTertiary : NookTheme.violet)
                    .frame(minWidth: 38, alignment: .leading)
                Text(change.title)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(NookDates.ago(change.date))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(hovering && url != nil ? DropdownStyle.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { hovering = $0 }
        .help(change.title + " · " + change.author)
    }
}
