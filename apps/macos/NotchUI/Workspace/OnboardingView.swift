import SwiftUI
import CoreGraphics

/// The first-run flow, in the main window: pick a brain that suits this Mac, allow what Nook needs, look at the optional
/// connections. Three steps, shown as a plan on top with a check for each one that is done; each can be skipped, and
/// nothing is switched on without a click.
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

    private let steps = 3

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
            header
            stepPlan
            Group {
                switch step {
                case 0: brainStep
                case 1: permissionsStep
                default: connectionsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .foregroundStyle(NookTheme.paper)
        .padding(NookTheme.Spacing.xxl)
        .frame(width: 600, height: 600)
        .background(NookTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(NookTheme.iris)
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
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            Text(tr("onboarding.brain.title")).font(NookTheme.TextStyle.strong)
            Text(tr("onboarding.brain.detail", EmbeddedModel.memoryGB)).foregroundStyle(NookTheme.textSecondary)
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
            Spacer(minLength: 0)
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

    /// The three steps by name, the current one highlighted and a check on each one that is done.
    private var stepPlan: some View {
        let _ = tick
        let titles = [tr("onboarding.plan.brain"), tr("onboarding.plan.permissions"), tr("onboarding.plan.connections")]
        let done = [settings.brainReady, missingPermissions.isEmpty, !app.connectors.active.isEmpty]
        return HStack(spacing: NookTheme.Spacing.md) {
            ForEach(0..<steps, id: \.self) { index in
                Button { step = index } label: {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Image(systemName: done[index] ? "checkmark.circle.fill" : "\(index + 1).circle")
                            .foregroundStyle(done[index] ? NookTheme.mint : (index == step ? NookTheme.paper : NookTheme.textSecondary))
                        Text(titles[index])
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(index == step ? NookTheme.paper : NookTheme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, NookTheme.Spacing.md)
                    .padding(.vertical, NookTheme.Spacing.sm)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                        .fill(index == step ? NookTheme.rowSelected : NookTheme.field))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(tr("onboarding.permissions.title")).font(NookTheme.TextStyle.strong)
            Text(tr("onboarding.permissions.detail")).foregroundStyle(NookTheme.textSecondary)
            ScrollView {
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
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            Text(tr("onboarding.connections.title")).font(NookTheme.TextStyle.strong)
            Text(tr("onboarding.connections.detail", app.connectors.active.count)).foregroundStyle(NookTheme.textSecondary)
            NookGhostButton(title: tr("onboarding.connections.open"), symbol: "link", compact: true, height: 32) {
                app.openSettings(section: .connections)
            }
            .fixedSize()
            Spacer(minLength: 0)
            Text(tr("onboarding.firstQuestion")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
        }
    }
}
