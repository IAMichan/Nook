import SwiftUI
import CoreGraphics

/// The first-run flow, in the main window: pick a brain that suits this Mac, allow what Nook needs, set up your coding
/// agents and projects, look at the optional connections. Four steps, shown as a plan on top with a check for each one
/// that is done; each can be skipped, and nothing is switched on without a click.
struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = PermissionMonitor.shared
    let onFinish: () -> Void

    @State private var step = 0
    @State private var recommendations: [ModelAdvisor.Recommendation] = []
    @State private var installing = false
    @State private var fraction = 0.0
    @State private var error: String?
    @State private var tick = 0

    private let steps = 4
    /// The "Coding agents" step, which the empty Agents tab opens directly (`AppModel.startOnboarding(at:)`).
    static let agentsStep = 2
    /// The room between the sheet's edge and its content, for the header, each step's page, and the footer.
    static let inset = NookTheme.Spacing.xxl

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                header
                stepPlan
            }
            .padding([.horizontal, .top], OnboardingView.inset)
            .padding(.bottom, NookTheme.Spacing.lg)
            // Each step is an `OnboardingPage`: it scrolls on its own, with the scroller at the sheet's edge.
            Group {
                switch step {
                case 0: brainStep
                case 1: permissionsStep
                case Self.agentsStep: OnboardingAgentsStep()
                default: connectionsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            NookDivider()
            footer
                .padding(.horizontal, OnboardingView.inset)
                .padding(.vertical, NookTheme.Spacing.lg)
        }
        .foregroundStyle(NookTheme.paper)
        // The sheet can be resized: the step plan folds to symbols and every step scrolls when it gets small.
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 960, minHeight: 460, idealHeight: 640, maxHeight: 960)
        .background(NookTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(NookTheme.iris)
        .onAppear { step = min(max(app.onboardingStep, 0), steps - 1) }
        .task { recommendations = await app.brainRecommendations() }
    }

    /// Nook himself next to the title, as in the panel's header, and how far along the plan is.
    private var header: some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            NookOrb(mood: step == steps - 1 ? .done : .seen, size: 40)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("onboarding.title")).font(NookTheme.TextStyle.heading)
                Text(tr("onboarding.step", step + 1, steps))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            NookGhostButton(title: tr("onboarding.later"), compact: true, height: 32) { onFinish() }
                .fixedSize()
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step > 0 {
                NookGhostButton(title: tr("onboarding.back"), compact: true, height: 32) { step -= 1 }
                    .fixedSize()
            }
            NookPrimaryButton(title: step == steps - 1 ? tr("onboarding.done") : tr("onboarding.next")) {
                if step == steps - 1 { onFinish() } else { step += 1 }
            }
            .fixedSize()
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 1 · Brain

    private var brainStep: some View {
        OnboardingPage(title: tr("onboarding.brain.title"), detail: tr("onboarding.brain.detail", EmbeddedModel.memoryGB)) {
            if settings.brainReady {
                Label(tr("settings.checklist.brain.ready", settings.activeModelName), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(NookTheme.mint)
            } else if let best = recommendations.first {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    Text(AppModel.title(of: best)).fontWeight(.semibold)
                    Text(best.reason).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                    if best.choice != .unavailable {
                        HStack {
                            NookPrimaryButton(title: best.ready ? tr("brain.advice.use") : tr("brain.advice.install")) { use(best) }
                                .fixedSize()
                                .disabled(installing)
                            if installing { ProgressView(value: fraction).frame(width: 120) }
                        }
                    }
                }
                .padding(NookTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard()
            } else {
                ProgressView()
            }
            if let error { Text(error).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.coral) }
            Button(tr("onboarding.brain.external")) { app.openSettings(section: .brain) }
                .buttonStyle(.link)
                .foregroundStyle(NookTheme.blue)
        }
    }

    private func use(_ recommendation: ModelAdvisor.Recommendation) {
        installing = true
        error = nil
        Task { @MainActor in
            defer { installing = false }
            do {
                try await app.useRecommendation(recommendation) { value in Task { @MainActor in fraction = value } }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Step plan

    /// The steps by name, the current one highlighted and a check on each one that is done. A name never wraps: when
    /// the four do not fit on one line, only the current step keeps its name and the others show their number or check.
    private var stepPlan: some View {
        ViewThatFits(in: .horizontal) {
            stepPlanRow(compact: false)
            stepPlanRow(compact: true)
        }
    }

    private func stepPlanRow(compact: Bool) -> some View {
        let _ = tick
        let titles = [tr("onboarding.plan.brain"), tr("onboarding.plan.permissions"), tr("onboarding.plan.agents"),
                      tr("onboarding.plan.connections")]
        let done = [settings.brainReady, missingPermissions.isEmpty, !app.connectedProviders.isEmpty, !app.connectors.active.isEmpty]
        return HStack(spacing: NookTheme.Spacing.md) {
            ForEach(0..<steps, id: \.self) { index in
                let current = index == step
                let named = !compact || current
                Button { step = index } label: {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Image(systemName: done[index] ? "checkmark.circle.fill" : "\(index + 1).circle")
                            .foregroundStyle(done[index] ? NookTheme.mint : (current ? NookTheme.paper : NookTheme.textSecondary))
                        if named {
                            Text(titles[index])
                                .font(NookTheme.TextStyle.label)
                                .foregroundStyle(current ? NookTheme.paper : NookTheme.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, NookTheme.Spacing.md)
                    .padding(.vertical, NookTheme.Spacing.sm)
                    .frame(maxWidth: named ? .infinity : nil)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                        .fill(current ? NookTheme.rowSelected : NookTheme.field))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(titles[index])
                .accessibilityLabel(titles[index])
                .layoutPriority(current ? 1 : 0)
            }
        }
    }

    // MARK: 2 · Permissions

    /// The recommended permissions not given yet. Only these count for the step's check and the "Allow" button that
    /// walks through them; an optional one is never asked for unless you click it yourself.
    private var missingPermissions: [SystemPermission] {
        SystemPermission.allCases.filter { $0.isRecommended && !permissions.isGranted($0) }
    }

    /// Every permission Nook can use as a checklist, in two groups: the two the setup recommends, and the optional rest,
    /// each marked as such and said to be skippable, so a sensitive one (contacts, the microphone) is never mistaken for
    /// something Nook needs.
    private var permissionsStep: some View {
        let _ = tick
        let recommended = SystemPermission.allCases.filter(\.isRecommended)
        let optional = SystemPermission.allCases.filter { !$0.isRecommended }
        let missing = missingPermissions
        return OnboardingPage(title: tr("onboarding.permissions.title"), detail: tr("onboarding.permissions.detail")) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                HStack {
                    NookSectionLabel(tr("onboarding.permissions.recommended"), inset: 0)
                    Text(tr("onboarding.permissions.progress", recommended.count - missing.count, recommended.count))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(missing.isEmpty ? NookTheme.mint : NookTheme.textSecondary)
                        .monospacedDigit()
                    Spacer()
                    if let next = missing.first {
                        SmallPrimaryButton(title: tr("onboarding.permissions.allowNext", next.title), systemName: "checkmark") {
                            app.requestPermission { await permissions.request(next, app: app); tick += 1 }
                        }
                    }
                }
                ForEach(recommended) { permission in
                    permissionRow(permission, granted: permissions.isGranted(permission))
                }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    NookSectionLabel(tr("onboarding.permissions.optional"), inset: 0)
                    Text(tr("onboarding.permissions.optionalDetail"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, NookTheme.Spacing.lg)
                ForEach(optional) { permission in
                    permissionRow(permission, granted: permissions.isGranted(permission))
                }
                keychainNote
                    .padding(.top, NookTheme.Spacing.lg)
            }
        }
        .onAppear { permissions.watch() }
        .onDisappear { permissions.unwatch() }
    }

    /// One permission: a check once given, what it is for, "Optional" on one Nook does without, and its own button.
    private func permissionRow(_ permission: SystemPermission, granted: Bool) -> some View {
        StatusRow(title: permission.title, detail: permission.detail, state: granted ? .done : .todo) {
            HStack(spacing: NookTheme.Spacing.md) {
                if !permission.isRecommended && !granted {
                    Text(tr("onboarding.permissions.optionalBadge"))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                        .padding(.horizontal, NookTheme.Spacing.md)
                        .padding(.vertical, NookTheme.Spacing.xxs)
                        .background(Capsule().fill(NookTheme.smoke))
                }
                if !granted {
                    SmallGhostButton(title: tr("button.allow")) {
                        app.requestPermission { await permissions.request(permission, app: app); tick += 1 }
                    }
                }
            }
        }
        .padding(NookTheme.Spacing.md)
        .panelCard()
    }

    /// macOS asks for the login password before Nook reads its keys from the Keychain; "Always Allow" makes that the
    /// only time.
    private var keychainNote: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
            Image(systemName: "key").foregroundStyle(NookTheme.textSecondary).frame(width: 22)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("onboarding.keychain.title"))
                Text(tr("onboarding.keychain.detail"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NookTheme.Spacing.md)
        .panelCard()
    }

    // MARK: 3 · Connections

    private var connectionsStep: some View {
        OnboardingPage(title: tr("onboarding.connections.title"),
                       detail: tr("onboarding.connections.detail", app.connectors.active.count)) {
            NookGhostButton(title: tr("onboarding.connections.open"), symbol: "link", compact: true, height: 32) {
                app.openSettings(section: .connections)
            }
            .fixedSize()
            Text(tr("onboarding.firstQuestion"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NookTheme.Spacing.md)
        }
    }
}

/// One step of the first-run flow: its title and what it is about, then its content, in a scroll view that spans the
/// sheet's width so the scroller sits at the edge and never over a row. The text wraps instead of being cut off.
struct OnboardingPage<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    Text(title).font(NookTheme.TextStyle.strong)
                    Text(detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OnboardingView.inset)
            .padding(.top, NookTheme.Spacing.md)
            .padding(.bottom, NookTheme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
