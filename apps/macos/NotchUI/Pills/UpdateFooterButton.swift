import SwiftUI

/// The update button in the panel footer. It only shows when there is something to say: a merged pull request this
/// build does not have yet, the install running, a restart that waits for you, a failed install, or, right after the
/// restart, that the update went in. Run from Xcode, a build there instead of the restart. With nothing to say it shows
/// `idle` (the footer's refresh button) in its place. Clicking it opens `UpdatePanel`; nothing installs without its button.
struct UpdateFooterButton<Idle: View>: View {
    @ViewBuilder var idle: () -> Idle
    @ObservedObject private var updater = AppUpdater.shared
    @State private var open = false
    @State private var hovering = false

    private struct Look: Equatable {
        let id: String
        let symbol: String?
        let label: String
        let tint: Color
        let help: String
        var count: Int? = nil
        var busy = false
    }

    private var look: Look? {
        switch updater.phase {
        case .available:
            guard let update = updater.available else { return nil }
            return Look(id: "available", symbol: "arrow.down.circle.fill", label: tr("update.button"), tint: NookTheme.mint,
                        help: tr("update.button.help", update.count), count: update.count)
        case .installing(let step):
            return Look(id: "installing", symbol: nil, label: tr("update.button.installing"), tint: NookTheme.iris,
                        help: UpdateText.step(step), busy: true)
        case .readyToRestart:
            return Look(id: "restart", symbol: "arrow.clockwise.circle.fill", label: tr("update.button.restart"),
                        tint: NookTheme.mint, help: tr("update.ready.title"))
        case .readyToBuildInXcode:
            return Look(id: "xcode", symbol: "hammer.circle.fill", label: tr("update.button.xcode"), tint: NookTheme.mint,
                        help: tr("update.xcode.title"))
        case .failed:
            return Look(id: "failed", symbol: "exclamationmark.triangle.fill", label: tr("update.button.failed"),
                        tint: NookTheme.coral, help: tr("update.failed.title"))
        case .unavailable, .idle, .checking, .upToDate:
            guard updater.receipt != nil else { return nil }
            return Look(id: "updated", symbol: "checkmark.circle.fill", label: tr("update.button.updated"), tint: NookTheme.mint,
                        help: tr("update.updated.title"))
        }
    }

    var body: some View {
        ZStack {
            if let look {
                Button { open.toggle() } label: {
                    // Narrow list: the symbol (or spinner) and the count are enough.
                    ViewThatFits(in: .horizontal) {
                        pill(look, showLabel: true)
                        pill(look, showLabel: false)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(look.help)
                .accessibilityLabel(look.help)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    UpdatePanel { open = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else {
                idle().transition(.opacity)
            }
        }
        .animation(NookTheme.swap, value: look?.id)
        .onAppear {
            updater.checkIfStale()
            if updater.panelRequested { present() }
        }
        .onChange(of: updater.panelRequested) { _, requested in
            if requested { present() }
        }
    }

    /// Opened from the menu bar or Settings: wait for the notch to finish opening so the popover finds its place.
    private func present() {
        updater.panelRequested = false
        guard look != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            open = true
        }
    }

    private func pill(_ look: Look, showLabel: Bool) -> some View {
        HStack(spacing: 5) {
            if look.busy {
                ProgressView().controlSize(.mini).tint(look.tint)
            } else if let symbol = look.symbol {
                Image(systemName: symbol).font(NookTheme.font(11.5, .semibold))
            }
            if showLabel {
                Text(look.label).font(NookTheme.font(12, .semibold)).lineLimit(1).fixedSize()
            }
            if let count = look.count {
                Text("\(count)")
                    .font(NookTheme.font(10.5, .bold))
                    .monospacedDigit()
                    .foregroundStyle(NookTheme.ink)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(look.tint))
            }
        }
        .foregroundStyle(look.tint)
        .padding(.leading, 8)
        .padding(.trailing, look.count == nil ? 9 : 5)
        .frame(height: 26)
        .cardBackground(look.tint.opacity(hovering || open ? 0.22 : 0.13), stroke: look.tint.opacity(0.32), radius: NookTheme.Radius.panel,
                        style: .continuous)
        .overlay(alignment: .topTrailing) {
            // A new update pulses once in a while until you have looked at it.
            if look.id == "available", !updater.seen {
                PulseDot(color: look.tint, animated: true).offset(x: 2, y: -2)
            }
        }
        .contentShape(Capsule())
        .hoverLift(hovering)
        .fixedSize()
    }
}

/// The texts the button, the panel and Settings share.
enum UpdateText {
    static func step(_ step: UpdateStep) -> String {
        switch step {
        case .fetch: return tr("update.step.fetch")
        case .merge: return tr("update.step.merge")
        case .generate: return tr("update.step.generate")
        case .build: return tr("update.step.build")
        case .install: return tr("update.step.install")
        case .restart: return tr("update.step.restart")
        }
    }

    static func activity(_ activity: BuildActivity) -> String {
        switch activity {
        case .resolvingPackages: return tr("update.activity.packages")
        case .compiling(let file): return tr("update.activity.compiling", file)
        case .linking: return tr("update.activity.linking")
        case .copying: return tr("update.activity.copying")
        case .signing: return tr("update.activity.signing")
        }
    }

    static func blocker(_ blocker: UpdateBlocker, branch: String) -> String {
        switch blocker {
        case .otherBranch(let current): return tr("update.blocked.otherBranch", current, branch)
        case .detached: return tr("update.blocked.detached", branch)
        case .diverged(let commits): return tr("update.blocked.diverged", branch, commits)
        }
    }

    static func reason(_ reason: UpdateFailure.Reason, branch: String) -> String {
        switch reason {
        case .blocked(let blocker): return Self.blocker(blocker, branch: branch)
        case .needsStash(let files): return tr("update.reason.needsStash", files)
        case .stashConflict(let name): return tr("update.reason.stashConflict", name)
        case .missingTool(let tool): return tr("update.reason.missingTool", tool, tool)
        case .command(let status): return tr("update.reason.command", Int(status))
        case .timedOut: return tr("update.reason.timedOut")
        case .noProduct: return tr("update.reason.noProduct")
        case .notWritable(let folder): return tr("update.reason.notWritable", folder)
        case .copyFailed(let message): return tr("update.reason.copyFailed", message)
        case .cancelled: return tr("update.reason.cancelled")
        case .other(let message): return message
        }
    }
}
