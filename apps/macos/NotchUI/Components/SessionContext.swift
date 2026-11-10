import Combine
import SwiftUI

/// The session whose composer takes what the side panel hands over. Nil outside a session, where nothing is offered.
struct SessionContextTarget: Equatable {
    let run: UUID?
    let directory: String
}

extension EnvironmentValues {
    @Entry var sessionContextTarget: SessionContextTarget?
}

/// From the side panel to the composer of the session beside it. Text only lands in the draft: nothing is sent until
/// you send it, for every agent alike. Both composers (a session Nook runs, one in a terminal) take from here.
@MainActor
final class ComposerInbox: ObservableObject {
    static let shared = ComposerInbox()

    struct Delivery: Equatable {
        let id = UUID()
        let target: SessionContextTarget
        let text: String
        /// Pictures for the composer's strip (a window capture).
        var images: [ImageAttachment] = []
        /// Files the agent reads itself, as tiles above the box (a window capture's text).
        var files: [ContextRef] = []

        /// The draft after this lands in it: the text as a block above what you wrote, the files at its end.
        func merged(into draft: String) -> String {
            var result = text.isEmpty ? draft : SessionPrompts.merging(text, into: draft)
            for file in files { result = ComposerAttachments.appending(file, to: result) }
            return result
        }
    }

    /// Written only when something is handed over, so idle composers see nothing.
    @Published private(set) var delivery: Delivery?

    func add(_ text: String, to target: SessionContextTarget) {
        delivery = Delivery(target: target, text: text)
        ToastCenter.shared.success(tr("session.context.added"))
    }

    /// Pictures and files (with optional text) for a session's composer; `confirmation` is the toast that says so.
    func add(images: [ImageAttachment], files: [ContextRef], text: String = "", to target: SessionContextTarget, confirmation: String) {
        delivery = Delivery(target: target, text: text, images: images, files: files)
        ToastCenter.shared.success(confirmation)
    }

    /// What is meant for this composer, once; nil when it is meant for another session.
    func take(run: UUID?, directory: String) -> Delivery? {
        guard let delivery else { return nil }
        let target = delivery.target
        let matches: Bool
        if let wanted = target.run, let run {
            matches = wanted == run
        } else {
            matches = !directory.isEmpty && WorkspacePathPolicy.normalize(target.directory) == WorkspacePathPolicy.normalize(directory)
        }
        guard matches else { return nil }
        self.delivery = nil
        return delivery
    }
}

extension PullRequestDetail {
    /// What a prompt says about this pull request.
    var sessionRef: SessionPullRequestRef {
        SessionPullRequestRef(number: number, title: title, url: url?.absoluteString ?? "", headBranch: headBranch, baseBranch: baseBranch)
    }

    var failingCheckNames: [String] { checks.filter { $0.outcome == .failing }.map(\.name) }

    /// The comments still open that ask for something: not a bot's, not a finished conversation's, not an approval.
    var sessionFindings: [SessionPrompts.Finding] {
        PullRequestConversation.filtered(PullRequestConversation.items(events), bots: false, finished: false).compactMap { item in
            let root = item.root
            guard !root.body.isEmpty else { return nil }
            switch root.kind {
            case .lineComment(let path, let line):
                return SessionPrompts.Finding(author: root.author, path: path, line: line, text: root.body)
            case .review(let state) where state != "APPROVED":
                return SessionPrompts.Finding(author: root.author, path: nil, line: nil, text: root.body)
            default:
                return nil
            }
        }
    }
}

extension EnvironmentValues {
    /// The pull request on the page, so a comment card can hand itself to the session.
    @Entry var sessionPullRequestRef: SessionPullRequestRef?
}

/// A hammer that puts a fix for this in the session's composer. Quiet, in a row of its own kind of controls.
struct SessionFixButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        ToolbarIconButton("hammer", help, action)
    }
}

/// A pull request's description with its task boxes as controls. Ticking one rewrites the description, so it goes
/// through the page's confirmation like every other change on GitHub.
struct PullRequestDescription: View {
    let text: String
    let editable: Bool
    let setChecked: (Int, Bool) -> Void

    var body: some View {
        let segments = MarkdownTasks.segments(text)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    MarkdownView(text: text, size: 14)
                case .task(let line, let checked, let text):
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                        Button { setChecked(line, !checked) } label: {
                            Image(icon: checked ? "checkmark.square.fill" : "square")
                                .font(NookTheme.TextStyle.body)
                                .foregroundStyle(checked ? NookTheme.mint : NookTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!editable)
                        .accessibilityLabel(text)
                        .accessibilityValue(tr(checked ? "agents.pr.task.done" : "agents.pr.task.open"))
                        MarkdownView(text: text, size: 14)
                    }
                }
            }
        }
    }
}
