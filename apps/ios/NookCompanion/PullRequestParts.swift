import SwiftUI

// The parts of the Pull requests page that came with `CompanionFeature.pullActions` (docs/COMPANION.md, "Pull
// requests"): label chips, the review decision as a word, the Summary's side info and the Conversation tab with its
// threads, as the Mac's `PullRequestRow`, `PullRequestDetailView+Summary` and `PullRequestConversationView` show them.

/// A pull request's labels as the Mac's `LabelChip`s: a colored dot and the name in a quiet outline, at most `limit`
/// with "+2" for the rest.
struct PullLabels: View {
    let labels: [String]
    let colors: [String: String]
    var limit = Int.max

    var body: some View {
        let shown = Array(labels.prefix(limit))
        ViewThatFits(in: .horizontal) {
            row(shown, rest: labels.count - shown.count)
            row(Array(shown.prefix(1)), rest: labels.count - 1)
        }
    }

    private func row(_ names: [String], rest: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: Theme.Spacing.xs) {
                    Circle().fill(Color(hexString: colors[name]) ?? Theme.textTertiary).frame(width: 7, height: 7)
                    Text(verbatim: name).lineLimit(1)
                }
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 1)
                .background(Theme.shape(Theme.Radius.chip).strokeBorder(Theme.line2))
            }
            if rest > 0 {
                Text(verbatim: "+\(rest)").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the reviews decided, as the Mac's row says it: approved, changes requested, or review required.
struct PullReviewWord: View {
    let review: String

    init?(review: String) {
        guard ["approved", "changesRequested", "required"].contains(review) else { return nil }
        self.review = review
    }

    var body: some View {
        switch review {
        case "approved": Label("Approved", systemImage: "checkmark.seal").foregroundStyle(Theme.mint)
        case "changesRequested": Label("Changes requested", systemImage: "exclamationmark.bubble").foregroundStyle(Theme.amber)
        default: Label("Review required", systemImage: "eye").foregroundStyle(Theme.textTertiary)
        }
    }
}

/// The Summary's side info on the Mac, as one card under the header: reviewers asked, assignees, labels, milestone, the
/// issues it closes, auto-merge, and a branch behind its base (with Update branch when the Mac offers it).
struct PullSideInfo: View {
    let detail: PullDetailDigest
    let canUpdate: Bool
    let update: () -> Void

    private var isEmpty: Bool {
        (detail.reviewers ?? []).isEmpty && (detail.assignees ?? []).isEmpty && (detail.labels ?? []).isEmpty
            && detail.milestone == nil && (detail.issues ?? []).isEmpty && detail.autoMerge == nil && detail.behind != true
    }

    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let people = detail.reviewers, !people.isEmpty { row(String(localized: "Reviewers"), people.joined(separator: ", ")) }
                if let people = detail.assignees, !people.isEmpty { row(String(localized: "Assignees"), people.joined(separator: ", ")) }
                if let labels = detail.labels, !labels.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        name(String(localized: "Labels"))
                        PullLabels(labels: labels, colors: detail.labelColors ?? [:], limit: 6)
                    }
                }
                if let milestone = detail.milestone { row(String(localized: "Milestone"), milestone) }
                if let issues = detail.issues, !issues.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        name(String(localized: "Closes"))
                        ForEach(issues) { issue in
                            Button {
                                if let link = issue.url.flatMap(URL.init(string:)) { UIApplication.shared.open(link) }
                            } label: {
                                Label {
                                    Text(verbatim: "#\(issue.number) \(issue.title)").lineLimit(2)
                                } icon: {
                                    Image(icon: issue.open ? "circle.dotted" : "checkmark.circle").foregroundStyle(issue.open ? Theme.mint : Theme.violet)
                                }
                                .font(Theme.TextStyle.detail).foregroundStyle(Theme.paper)
                            }
                            .buttonStyle(PressFade())
                            .disabled(issue.url == nil)
                        }
                    }
                }
                if let auto = detail.autoMerge {
                    Label(auto.by.isEmpty ? String(localized: "Auto-merge is on") : String(localized: "Auto-merge is on, by \(auto.by)"),
                          systemImage: "bolt.fill")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.mint)
                }
                if detail.behind == true {
                    HStack(spacing: Theme.Spacing.md) {
                        Label("Behind \(detail.baseBranch)", systemImage: "arrow.triangle.branch")
                            .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
                        Spacer(minLength: 0)
                        if canUpdate {
                            Button("Update branch", action: update)
                                .font(Theme.TextStyle.label).foregroundStyle(Theme.paper)
                                .frame(minHeight: 44)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: Theme.Spacing.lg)
        }
    }

    private func name(_ text: String) -> some View {
        Text(text).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            name(title)
            Text(verbatim: value).font(Theme.TextStyle.detail).foregroundStyle(Theme.paper)
        }
    }
}

/// The Conversation tab, the Mac's `PullRequestConversationView` for a phone: the comments and reviews, then each thread
/// on a line with its replies, Reply and Resolve; a comment of your own at the end.
struct PullConversationView: View {
    @EnvironmentObject private var client: CompanionClient
    let detail: PullDetailDigest
    let mayAct: Bool
    let busy: Bool
    let send: (CompanionPullAction) async -> Void
    @State private var text = ""
    @State private var replying: PullDetailDigest.Thread?
    @State private var reply = ""
    @State private var showResolved = false

    private var notes: [PullDetailDigest.Note] { detail.conversation ?? [] }
    private var threads: [PullDetailDigest.Thread] { detail.threads ?? [] }
    private var resolvedCount: Int { threads.count(where: \.resolved) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { content }
            .alert("Reply", isPresented: Binding(get: { replying != nil }, set: { if !$0 { replying = nil } })) {
                TextField("Your reply", text: $reply, axis: .vertical)
                Button("Send") {
                    let words = reply
                    let thread = replying?.id
                    reply = ""
                    Task { await send(CompanionPullAction(kind: .reply, body: words, thread: thread)) }
                }
                Button("Cancel", role: .cancel) { reply = "" }
            } message: {
                if let replying { Text(verbatim: "\(replying.path)\(replying.line.map { ":\($0)" } ?? "")") }
            }
    }

    @ViewBuilder
    private var content: some View {
        if notes.isEmpty && threads.isEmpty {
            Text("No comments yet.").font(Theme.TextStyle.body).foregroundStyle(Theme.textTertiary)
        }
        ForEach(notes) { note in
            NoteCard(note: note).card(padding: Theme.Spacing.lg)
        }
        if !threads.isEmpty {
            SectionHeader(title: String(localized: "Threads"), count: threads.count - resolvedCount)
            ForEach(threads.filter { showResolved || !$0.resolved }) { thread in threadCard(thread) }
            if resolvedCount > 0 {
                Button {
                    withAnimation(Theme.reveal) { showResolved.toggle() }
                } label: {
                    Text(showResolved ? String(localized: "Hide resolved threads") : String(localized: "Show \(resolvedCount) resolved threads"))
                        .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary).frame(minHeight: 44)
                }
            }
        }
        if mayAct, client.pullAllows(detail, .note) {
            SessionComposer(text: $text, prompt: "Add a comment", minHeight: 44, lines: 1...8,
                            canSend: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sending: busy) {
                let words = text
                Task {
                    await send(CompanionPullAction(kind: .note, body: words))
                    text = ""
                }
            }
            .padding(.top, Theme.Spacing.md)
        }
    }

    private func threadCard(_ thread: PullDetailDigest.Thread) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: (thread.path as NSString).lastPathComponent + (thread.line.map { ":\($0)" } ?? ""))
                    .font(Theme.TextStyle.code).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                if thread.resolved { Text("Resolved").font(Theme.TextStyle.caption).foregroundStyle(Theme.mint) }
                if thread.outdated { Text("Outdated").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary) }
                Spacer(minLength: 0)
            }
            ForEach(thread.comments) { note in NoteCard(note: note) }
            if mayAct {
                HStack(spacing: Theme.Spacing.lg) {
                    if thread.canReply, client.pullAllows(detail, .reply) {
                        Button { replying = thread } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    }
                    if thread.canResolve {
                        let kind: CompanionPullAction.Kind = thread.resolved ? .unresolve : .resolve
                        if client.pullAllows(detail, kind) {
                            Button { Task { await send(CompanionPullAction(kind: kind, thread: thread.id)) } } label: {
                                Label(thread.resolved ? String(localized: "Unresolve") : String(localized: "Resolve"),
                                      systemImage: thread.resolved ? "arrow.uturn.backward" : "checkmark.circle")
                            }
                            .disabled(busy)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(Theme.TextStyle.label).foregroundStyle(Theme.paper)
                .frame(minHeight: 44)
            }
        }
        .card(padding: Theme.Spacing.lg)
        .opacity(thread.resolved ? 0.7 : 1)
    }
}

/// One comment or review: who, when, the verdict, the words.
private struct NoteCard: View {
    let note: PullDetailDigest.Note

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: note.author).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
                if let verdict = note.verdict { verdictMark(verdict) }
                Spacer(minLength: 0)
                if let date = note.date {
                    Text(AgentRow.age(Date().timeIntervalSince1970 - date)).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            if !note.body.isEmpty { RichMessageText(text: note.body) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func verdictMark(_ verdict: String) -> some View {
        switch verdict {
        case "APPROVED": Label("approved", systemImage: "checkmark.seal").font(Theme.TextStyle.caption).foregroundStyle(Theme.mint)
        case "CHANGES_REQUESTED":
            Label("asked for changes", systemImage: "exclamationmark.bubble").font(Theme.TextStyle.caption).foregroundStyle(Theme.amber)
        case "DISMISSED": Text("dismissed").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
        default: Text("reviewed").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
        }
    }
}
