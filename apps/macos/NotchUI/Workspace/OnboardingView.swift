import SwiftUI
import CoreGraphics

/// The first-run flow, in the main window: pick a brain that suits this Mac, allow what Nook needs, look at the optional
/// connections. Three steps, each can be skipped; nothing is switched on without a click.
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(tr("onboarding.title")).font(NookTheme.TextStyle.heading)
                Spacer()
                Text(tr("onboarding.step", step + 1, steps)).foregroundStyle(NookTheme.textSecondary).monospacedDigit()
            }
            ProgressView(value: Double(step + 1), total: Double(steps))
            Group {
                switch step {
                case 0: brainStep
                case 1: permissionsStep
                default: connectionsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button(tr("onboarding.later")) { onFinish() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button(tr("onboarding.back")) { step -= 1 } }
                Button(step == steps - 1 ? tr("onboarding.done") : tr("onboarding.next")) {
                    if step == steps - 1 { onFinish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .task { recommendations = await app.brainRecommendations() }
    }

    // MARK: 1 · Brain

    private var brainStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("onboarding.brain.title")).font(NookTheme.TextStyle.strong)
            Text(tr("onboarding.brain.detail", EmbeddedModel.memoryGB)).foregroundStyle(NookTheme.textSecondary)
            if settings.brainReady {
                Label(tr("settings.checklist.brain.ready", settings.activeModelName), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(NookTheme.mint)
            } else if let best = recommendations.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppModel.title(of: best)).fontWeight(.semibold)
                    Text(best.reason).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                    if best.choice != .unavailable {
                        HStack {
                            Button(best.ready ? tr("brain.advice.use") : tr("brain.advice.install")) { use(best) }
                                .buttonStyle(.borderedProminent)
                                .disabled(installing)
                            if installing { ProgressView(value: fraction).frame(width: 120) }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card).fill(Color.primary.opacity(0.05)))
            } else {
                ProgressView()
            }
            if let error { Text(error).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.coral) }
            Spacer(minLength: 0)
            Button(tr("onboarding.brain.external")) { app.openSettings(section: .brain) }
                .buttonStyle(.link)
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

    // MARK: 2 · Permissions

    private var permissionsStep: some View {
        let _ = tick
        return VStack(alignment: .leading, spacing: 12) {
            Text(tr("onboarding.permissions.title")).font(NookTheme.TextStyle.strong)
            Text(tr("onboarding.permissions.detail")).foregroundStyle(NookTheme.textSecondary)
            permissionRow(tr("settings.checklist.screen"), granted: permissions.isGranted(.screen)) {
                await permissions.request(.screen, app: app)
            }
            permissionRow(tr("settings.checklist.calendar"), granted: permissions.isGranted(.calendar)) {
                await permissions.request(.calendar, app: app)
            }
            Spacer(minLength: 0)
        }
        .onAppear { permissions.watch() }
        .onDisappear { permissions.unwatch() }
    }

    private func permissionRow(_ title: String, granted: Bool, request: @escaping @MainActor () async -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? NookTheme.mint : NookTheme.textSecondary)
            Text(title)
            Spacer()
            if !granted {
                Button(tr("button.allow")) { app.requestPermission { await request(); tick += 1 } }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card).fill(Color.primary.opacity(0.05)))
    }

    // MARK: 3 · Connections

    private var connectionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("onboarding.connections.title")).font(NookTheme.TextStyle.strong)
            Text(tr("onboarding.connections.detail", app.connectors.active.count)).foregroundStyle(NookTheme.textSecondary)
            Button(tr("onboarding.connections.open")) { app.openSettings(section: .connections) }
            Spacer(minLength: 0)
            Text(tr("onboarding.firstQuestion")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
        }
    }
}
