import Foundation

/// A prompt link that arrived and waits for the "new session" composer to show it as a draft.
@MainActor
final class PromptLinkInbox: ObservableObject {
    static let shared = PromptLinkInbox()
    @Published var pending: PromptLink?
    /// A folder the composer should open on (the "+" beside a project in the Agents list); the task you typed stays.
    /// Every composer on screen takes it (the notch and the main window can both show one), so none clears it on its
    /// own: it goes once the composers that show now, or appear for it, have had it (`requestProject`).
    @Published private(set) var pendingProject: ProjectRequest?

    struct ProjectRequest: Equatable {
        let id = UUID()
        let path: String
    }

    /// Asks the composers for `path`, also when one already shows another folder or the same request came before.
    func requestProject(_ path: String) {
        let request = ProjectRequest(path: path)
        pendingProject = request
        // Long enough for a composer that opens for it to appear; after that a composer that appears later (another
        // session's, after you moved on) must not jump back to this folder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if self?.pendingProject == request { self?.pendingProject = nil }
        }
    }
}
