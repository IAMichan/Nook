import SwiftUI

extension WSEmptyState where Actions == SmallGhostButton {
    /// A pane whose content could not be read, in its place: a warning symbol, what failed, why (the error's own words)
    /// and one button to read it again. Every load error that replaces a pane's content uses it, so each says it the
    /// same way.
    init(loadFailed title: String, message: String?, retryTitle: String = tr("button.tryAgain"),
         retry: @escaping () -> Void) {
        self.init(symbol: "exclamationmark.triangle", title: title, message: message) {
            SmallGhostButton(title: retryTitle, action: retry)
        }
    }
}

/// A part of a view that could not be read, inside what did load (a mail in a conversation, a section of a card): why,
/// in soft coral, and a button to try again, with room for one more way out (`extra`, such as "Open in Mail"). A whole
/// pane that failed is a `WSEmptyState(loadFailed:)` instead.
struct LoadFailedNote<Extra: View>: View {
    let message: String
    var retryTitle: String = tr("button.tryAgain")
    let retry: () -> Void
    @ViewBuilder var extra: () -> Extra

    init(_ message: String, retryTitle: String = tr("button.tryAgain"), retry: @escaping () -> Void,
         @ViewBuilder extra: @escaping () -> Extra) {
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
        self.extra = extra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            InlineErrorText(message)
            HStack(spacing: NookTheme.Spacing.sm) {
                SmallGhostButton(title: retryTitle, action: retry)
                extra()
            }
        }
    }
}

extension LoadFailedNote where Extra == EmptyView {
    init(_ message: String, retryTitle: String = tr("button.tryAgain"), retry: @escaping () -> Void) {
        self.init(message, retryTitle: retryTitle, retry: retry) { EmptyView() }
    }
}
