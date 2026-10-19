import Foundation

/// A prompt link that arrived and waits for the "new session" composer to show it as a draft.
@MainActor
final class PromptLinkInbox: ObservableObject {
    static let shared = PromptLinkInbox()
    @Published var pending: PromptLink?
}
