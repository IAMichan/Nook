import SwiftUI

// MARK: What Nook could do next

/// What Nook could do for what was just said (`ActionSuggestionDigest`), above the composer of a session, a chat with
/// Nook and a chat of your apps, as the Mac's suggestion bar: the steps, why, *Do it* and the cross. *Do it* runs them on
/// the Mac after your tap (anything risky still asks there); while they run it says so, then what came of it.
struct SuggestionCard: View {
    @EnvironmentObject private var client: CompanionClient
    let suggestion: ActionSuggestionDigest
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(icon: "sparkles").foregroundStyle(Theme.iris)
                Text("Nook suggests").font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: Theme.Spacing.sm)
                if suggestion.state != .running {
                    Button { act(.dismiss) } label: {
                        Image(icon: "xmark").font(Theme.font(10, .bold)).foregroundStyle(Theme.textTertiary)
                            .frame(width: 32, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(PressFade())
                    .accessibilityLabel("Dismiss")
                }
            }
            ForEach(Array(suggestion.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Image(icon: step.symbol).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).frame(width: 18)
                    Text(verbatim: step.text).font(Theme.TextStyle.body).foregroundStyle(Theme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reason = suggestion.reason, !reason.isEmpty, suggestion.state == .waiting {
                Text(verbatim: reason).font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch suggestion.state {
            case .waiting:
                Button { act(.run) } label: {
                    Label("Do it", systemImage: "checkmark")
                        .font(Theme.TextStyle.label).foregroundStyle(Theme.onIris)
                        .padding(.horizontal, Theme.Spacing.lg).frame(minHeight: 36)
                        .background(Capsule().fill(Theme.iris))
                }
                .buttonStyle(PressFade())
                .disabled(sent || !client.allows(.operate) || client.isOffline)
            case .running:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                }
            case .done:
                Label(suggestion.result ?? String(localized: "Done"), systemImage: "checkmark.circle")
                    .font(Theme.TextStyle.detail).foregroundStyle(Theme.mint)
            case .failed:
                Label(suggestion.result ?? String(localized: "Failed"), systemImage: "exclamationmark.triangle")
                    .font(Theme.TextStyle.detail).foregroundStyle(Theme.coral)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(Theme.field, radius: Theme.Radius.card)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .onChange(of: suggestion.state) { _, _ in sent = false }
    }

    private func act(_ act: SuggestionAct) {
        if act == .run {
            Haptics.success()
            sent = true
        } else {
            Haptics.tap()
        }
        Task { await client.actOnSuggestion(suggestion, act) }
    }
}
