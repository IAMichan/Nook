import Foundation

/// A prompt link that arrived and waits for the "new session" composer to show it as a draft.
@MainActor
final class PromptLinkInbox: ObservableObject {
    static let shared = PromptLinkInbox()
    @Published var pending: PromptLink?
    /// A folder the composer should open on (the "+" beside a project in the Agents list); the task you typed stays.
    @Published var pendingProject: String?
}
