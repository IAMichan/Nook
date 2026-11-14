import SwiftUI

/// What a panel shows while its content loads. Most loads take a fraction of a second, and a spinner that flashes for
/// that moment reads as the app being slow; this one stays invisible for `delay` and only then fades in, so a quick
/// load shows nothing at all and only a slow one says it is busy. Fills the space it is given, centered.
struct PatientSpinner: View {
    var delay: Duration = .milliseconds(350)
    @State private var shown = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                withAnimation(NookTheme.reveal) { shown = true }
            }
            .accessibilityLabel(tr("a11y.loading"))
    }
}
