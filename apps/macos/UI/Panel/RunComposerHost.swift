import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// What you are writing in a session's composer: the text, its pictures, the passages quoted into it, and the queued
/// message open in it. `AgentRunPanel` holds it without observing it.
@MainActor
final class RunComposerState: ObservableObject {
    /// The session the draft belongs to: each change to it is saved for that session, as you type.
    private(set) var session: String?
    private var switching = false
    @Published var draft = "" {
        didSet {
            guard !switching, draft != oldValue, let session else { return }
            ComposerDraftStore.shared.save(sessionID: session, text: draft)
        }
    }

    /// Shows the draft saved for `session` (empty when there is none), saving nothing on the way: clearing the box of
    /// the session you leave is not a change you made to its draft.
    func show(session: String) {
        switching = true
        defer { switching = false }
        // The pictures of the session you leave wait for it; a queued message open for editing belongs to that session's
        // queue, so it closes (the next send would otherwise overwrite a message in a queue that is not shown).
        if let previous = self.session, previous != session {
            heldImages[previous] = images.isEmpty ? nil : images
            images = heldImages.removeValue(forKey: session) ?? []
            editingQueued = nil
        }
        self.session = session
        draft = ComposerDraftStore.shared.draft(for: session) ?? ""
    }
    /// Pictures added in other sessions' composers and not sent yet, by session, while this panel is open.
    private var heldImages: [String: [ImageAttachment]] = [:]
    @Published var images: [ImageAttachment] = []
    /// Passages of answers picked for the next message (Quote / Ask about this), as chips above the composer.
    @Published var quotes = ComposerQuotes()
    /// A queued message that is being edited in the composer, and the draft that waits behind it.
    @Published var editingQueued: UUID?
}

/// Draws `content` again whenever `object` changes, without the view around it: that view can hold the object without
/// observing it.
struct Observing<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    @ViewBuilder let content: () -> Content

    init(_ object: Object, @ViewBuilder content: @escaping () -> Content) {
        self.object = object
        self.content = content
    }

    var body: some View { content() }
}

/// Two closures made once and kept, for `quoteSelection` and `askAboutSelection`: a closure written in `body` is a new
/// value on every redraw, and an environment value that changes redraws every view that reads it, past `.equatable()`.
@MainActor
final class StableSelectionActions {
    private var handler: ((String, Bool) -> Void)?
    private(set) lazy var quote: (String) -> Void = { [weak self] in self?.handler?($0, false) }
    private(set) lazy var ask: (String) -> Void = { [weak self] in self?.handler?($0, true) }

    /// Points both closures at `handler` (text, and whether to ask) and returns itself.
    func bind(_ handler: @escaping (String, Bool) -> Void) -> StableSelectionActions {
        self.handler = handler
        return self
    }
}

/// The session composer of `AgentRunPanel`. The panel redraws for every streamed token (it observes the timeline), and a
/// fresh composer closure is never equal to the last, so the composer, its five menus and their popovers were built again
/// up to 20 times a second while nothing in them changed. As an `Equatable` view it is built again only when what it shows
/// from the panel changes (`key`), or when one of the objects it reads publishes (it observes them itself).
struct RunComposerHost<Content: View>: View, Equatable {
    struct Key: Equatable {
        var run: WorkspaceRun
        var subagents: [SubagentInfo]
        var commands: [BackgroundCommandInfo]
        var skills: [Skill]
        var repository: String?
        var shownSubagents: Bool
        /// The panel's own state the tray reads (the folded earlier branches): without it here a click on the fold row
        /// changes the state but the composer is never drawn again, so the list never opens.
        var olderBranchesShown: Bool

        init(run: WorkspaceRun, subagents: [SubagentInfo], commands: [BackgroundCommandInfo], skills: [Skill], repository: String?,
             shownSubagents: Bool, olderBranchesShown: Bool) {
            // A streaming turn moves `updatedAt` every two seconds; the composer does not show it.
            var run = run
            run.updatedAt = .distantPast
            self.run = run
            self.subagents = subagents
            self.commands = commands
            self.skills = skills
            self.repository = repository
            self.shownSubagents = shownSubagents
            self.olderBranchesShown = olderBranchesShown
        }
    }

    @ObservedObject var state: RunComposerState
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var app: AppModel
    @ObservedObject var pullRequests: PullRequestSync
    let key: Key
    @ViewBuilder let content: () -> Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.state === rhs.state && lhs.workspace === rhs.workspace
    }

    var body: some View { content() }
}
