import SwiftUI
import UniformTypeIdentifiers

/// A question from the agent in place of the composer, one at a time: its options as buttons (keys 1–9
/// pick one), several for a multiple choice, or an answer of your own. A single choice moves on by itself; with several
/// questions, Back returns to an earlier one with its answer still picked, and what you had started on
/// the later one waits for you. Your own answer can carry files and pictures (attached, pasted or dropped), which go to
/// the agent as their paths below your words (`AnswerAttachments`), the same for every agent.
struct RunQuestionPanel: View {
    let question: PendingQuestion
    let agent: String
    /// The session's folder: the file picker starts there.
    var folder: String? = nil
    /// Stops the agent instead of answering (the composer with its Stop button is hidden meanwhile).
    var onStop: (() -> Void)? = nil
    /// Leaves a question nothing waits for unanswered (one asked before Nook restarted, `PendingQuestion.isRestored`).
    var onDismiss: (() -> Void)? = nil
    let onAnswer: ([String: [String]]) -> Void
    @State private var index = 0
    @State private var answers: [String: [String]] = [:]
    @State private var picks: Set<String> = []
    @State private var own = ""
    /// What you had picked and typed on a question you went back from, by question id.
    @State private var drafts: [String: QuestionDraft] = [:]
    @FocusState private var ownFocused: Bool
    /// Pictures and files that go with your own answer; the files are kept as the composer keeps them (links at the end
    /// of a text, see `ComposerAttachments`), with absolute paths.
    @State private var pictures: [ImageAttachment] = []
    @State private var attached = ""
    @State private var encodingPictures = 0
    @State private var drop = ComposerDrop()
    @State private var pasteMonitor = PasteMonitor()
    /// `@` in your own answer: people from your chats by name.
    @StateObject private var mentionModel = ComposerModel()
    /// Folded to its header and the question's first line, to read the conversation above it before answering.
    @State private var collapsed = false

    private var item: RunQuestion? { question.questions.indices.contains(index) ? question.questions[index] : nil }
    private var isLast: Bool { index >= question.questions.count - 1 }

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                HStack(spacing: NookTheme.Spacing.md) {
                    Image(icon: "questionmark.bubble.fill").foregroundStyle(NookTheme.amber)
                    Text(item.header.isEmpty ? tr("ws.question.title", agent) : item.header)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer(minLength: 6)
                    if index > 0 {
                        ToolbarIconButton("chevron.left", tr("ws.question.back")) { goBack() }
                    }
                    if question.questions.count > 1 {
                        Text("\(index + 1)/\(question.questions.count)")
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .monospacedDigit()
                    }
                    ToolbarIconButton(collapsed ? "chevron.up" : "chevron.down",
                                      collapsed ? tr("ws.question.expand") : tr("ws.question.collapse")) {
                        withAnimation(NookTheme.reveal) { collapsed.toggle() }
                    }
                    if let onDismiss {
                        ToolbarIconButton("xmark", tr("ws.question.dismiss")) { onDismiss() }
                    } else if let onStop {
                        ToolbarIconButton("xmark", tr("ws.question.stop")) { onStop() }
                    }
                }
                if question.isRestored {
                    // The agent that asked is gone after the restart: the answer reaches it as a message of yours.
                    Text(tr("ws.question.restoredNote"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if collapsed {
                    Text(TranscriptPresentation.headline(item.question))
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    // In Markdown, as the agent wrote it: code, bold and lists in a question read as such.
                    MarkdownView(text: item.question, size: 13)
                        .equatable()
                }

                if !collapsed {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                        let picked = picks.contains(option.label)
                        QuestionOptionRow(
                            option: option,
                            number: number,
                            isPicked: picked,
                            multiSelect: item.multiSelect
                        ) {
                            if item.multiSelect {
                                if picked { picks.remove(option.label) } else { picks.insert(option.label) }
                            } else {
                                record(item, [option.label])
                            }
                        }
                        // What the option would look like, under it (Claude Code's `preview`).
                        QuestionOptionPreview(text: QuestionPreview.display(option.preview), indent: QuestionOptionRow.labelIndent)
                            .padding(.bottom, option.preview.isEmpty ? 0 : NookTheme.Spacing.xs)
                    }
                }

                if item.allowsOther {
                    MentionSuggestions(model: mentionModel, text: $own, config: .mentions(), focus: $ownFocused)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                        if hasAttachments || drop.open {
                            ImageAttachmentStrip(images: pictures, files: attachedFiles, fileRoot: folder,
                                                 dropSlot: drop.hovering ? NookTheme.amber : nil,
                                                 remove: { picture in pictures.removeAll { $0.id == picture.id } },
                                                 removeFile: { attached = ComposerAttachments.removing(at: $0, from: attached) })
                                .transition(.opacity)
                        }
                        ownAnswerField(item)
                    }
                    .animation(NookTheme.reveal, value: drop)
                    .composerDrop(of: [UTType.fileURL, UTType.image], $drop) { receiveDrop($0) }
                }

                if item.multiSelect, !picks.isEmpty {
                    HStack {
                        Spacer()
                        NookPrimaryButton(title: isLast ? tr("ws.question.send") : tr("ws.question.next")) {
                            record(item, Array(picks))
                        }
                    }
                }
                }
            }
            .conversationCard()
            // Keys 1–9 pick an option, except while a text is being edited (your own answer).
            .onWindowKeyDown { digitKey($0, item) }
            // A question with no options but room for your own answer: the keyboard is in that field.
            .composerFocusOnAppear($ownFocused, enabled: asksOnlyOwn(item))
            .onChange(of: index) { _, _ in
                if asksOnlyOwn(item) { ownFocused = true }
            }
            .onAppear { startPasteMonitor() }
            .onDisappear { pasteMonitor.stop() }
        }
    }

    // MARK: Files with your own answer

    private var attachedFiles: [ContextRefs.Found] { ComposerAttachments.split(attached).files }
    private var hasAttachments: Bool { !pictures.isEmpty || !attachedFiles.isEmpty }
    /// Something to send as your own answer: words, or files alone. Not while a pasted picture is still being encoded.
    private var canSendOwn: Bool {
        encodingPictures == 0 && (!own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments)
    }

    private func attachFile() {
        guard let ref = ComposerFilePicker.pick(startingIn: folder ?? NSHomeDirectory()) else { return }
        attach(path: AnswerAttachments.absolutePath(ref.id, folder: folder), label: ref.label)
        ownFocused = true
    }

    private func attach(path: String, label: String) {
        attached = ComposerAttachments.appending(ContextRef(kind: .file, id: path, label: label), to: attached)
    }

    /// Cmd-V in your own answer with a picture or files on the clipboard attaches them; text pastes as always.
    private func startPasteMonitor() {
        guard question.questions.contains(where: \.allowsOther) else { return }
        pasteMonitor.start {
            guard ownFocused else { return false }
            let others = ImageAttachment.nonImageFiles()
            let claimed = ImageAttachment.fromPasteboard { made in
                encodingPictures = max(encodingPictures - 1, 0)
                pictures += made
            }
            if claimed { encodingPictures += 1 }
            for url in others { attach(path: url.standardizedFileURL.path, label: url.lastPathComponent) }
            return claimed || !others.isEmpty
        }
    }

    /// A path written into the field (a drop, "Copy as Pathname") attaches like the file itself.
    private func attachPastedPaths(old: String, new: String) {
        guard let found = PastedPaths.attaching(old: old, new: new) else { return }
        own = found.body
        for url in found.urls {
            ImageAttachment.take(url, images: { pictures += $0 }, file: { attach(path: $0.path, label: $0.lastPathComponent) })
        }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        ImageAttachment.receive(providers, images: { pictures += $0 }, file: { url in
            attach(path: url.standardizedFileURL.path, label: url.lastPathComponent)
        })
    }

    private func ownAnswerField(_ item: RunQuestion) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(icon: "pencil.line")
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(ownFocused ? NookTheme.amber : NookTheme.textTertiary)

            TextField(tr("ws.question.own"), text: $own, axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .lineLimit(1...6)
                .focused($ownFocused)
                .onSubmit { if !mentionModel.isOpen { submitOwn(item) } }
                .mentions(mentionModel, text: $own, config: .mentions())
                .onChange(of: own) { old, new in attachPastedPaths(old: old, new: new) }

            ToolbarIconButton("paperclip", tr("ws.question.attach")) { attachFile() }
                .help(tr("ws.question.attachHelp"))

            if canSendOwn {
                Button {
                    submitOwn(item)
                } label: {
                    HStack(spacing: 4) {
                        Text(isLast ? tr("ws.question.send") : tr("ws.question.next"))
                            .font(NookTheme.font(12, .semibold))
                        Image(icon: "return")
                            .font(NookTheme.font(10, .bold))
                    }
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.amber.opacity(0.35)))
                }
                .buttonStyle(.nookPlain)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm + 2)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.card)
        .overlay(
            NookTheme.shape(NookTheme.Radius.card)
                .stroke(ownFocused || drop.hovering ? NookTheme.amber.opacity(0.55) : NookTheme.wash.opacity(0.04),
                        style: StrokeStyle(lineWidth: 1, dash: drop.hovering ? [5, 4] : []))
        )
        .animation(NookTheme.hover, value: ownFocused)
        .animation(NookTheme.reveal, value: canSendOwn)
    }

    private func asksOnlyOwn(_ item: RunQuestion) -> Bool { item.options.isEmpty && item.allowsOther }

    /// Keys 1–9 choose an option (plain digits only, and not while a text is being edited).
    private func digitKey(_ event: NSEvent, _ item: RunQuestion) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad).isEmpty,
              !(NSApp.keyWindow?.firstResponder is NSTextView),
              let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit),
              item.options.indices.contains(digit - 1) else { return false }
        let option = item.options[digit - 1]
        if item.multiSelect {
            if picks.contains(option.label) { picks.remove(option.label) } else { picks.insert(option.label) }
        } else {
            record(item, [option.label])
        }
        return true
    }

    /// Your words, with the attached pictures (saved to Nook's folder first) and files as paths below them.
    private func submitOwn(_ item: RunQuestion) {
        guard canSendOwn else { return }
        let paths = pictures.compactMap { $0.writeToDisk()?.path }
            + attachedFiles.map { AnswerAttachments.absolutePath($0.id, folder: folder) }
        let text = AnswerAttachments.answer(own, paths: paths)
        guard !text.isEmpty else { return }
        pictures = []
        attached = ""
        record(item, Array(picks) + [text])
    }

    private func record(_ item: RunQuestion, _ values: [String]) {
        answers[item.id] = values
        if isLast {
            picks = []
            own = ""
            onAnswer(answers)
        } else {
            withAnimation(NookTheme.reveal) { index += 1 }
            restore(question.questions[index])
        }
    }

    /// Back to the previous question, with its answer picked again; what you started here is kept for later.
    private func goBack() {
        guard index > 0, let current = item else { return }
        drafts[current.id] = QuestionDraft(picks: picks, own: own)
        withAnimation(NookTheme.reveal) { index -= 1 }
        let previous = question.questions[index]
        let earlier = answers[previous.id] ?? []
        let labels = Set(previous.options.map(\.label))
        drafts[previous.id] = QuestionDraft(picks: Set(earlier.filter { labels.contains($0) }),
                                            own: earlier.first { !labels.contains($0) } ?? "")
        restore(previous)
    }

    private func restore(_ next: RunQuestion) {
        let draft = drafts[next.id]
        picks = draft?.picks ?? []
        own = draft?.own ?? ""
    }
}

/// An interactive option row with clear hover state, keycap badge, and intuitive indicator
private struct QuestionOptionRow: View {
    /// Where the option's words start: the row's padding, the keycap and the room after it.
    static let labelIndent = NookTheme.Spacing.md + 20 + NookTheme.Spacing.md

    let option: RunQuestionOption
    let number: Int
    let isPicked: Bool
    let multiSelect: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private var parsedLabel: (title: String, badge: String?) {
        let label = option.label
        for tag in ["(Recommended)", "(Aanbevolen)", "(Recommandé)", "(Recomendado)"] {
            if let range = label.range(of: tag, options: .caseInsensitive) {
                let title = label.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
                let cleanTag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                return (title, cleanTag)
            }
        }
        return (label, nil)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                // Keycap shortcut badge
                keycapBadge

                // Text: title + optional badge + description
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Text(parsedLabel.title)
                            .font(NookTheme.font(13, .semibold))
                            .foregroundStyle(isPicked ? NookTheme.paper : (isHovered ? NookTheme.paper : NookTheme.paper.opacity(0.92)))

                        if let badge = parsedLabel.badge {
                            Text(badge)
                                .font(NookTheme.font(10, .semibold))
                                .foregroundStyle(NookTheme.amber)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.amber.opacity(0.18)))
                        }
                    }

                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(isHovered || isPicked ? NookTheme.paper.opacity(0.78) : NookTheme.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The words take all the room, so they wrap at the same place whether or not the row is hovered.
                .frame(maxWidth: .infinity, alignment: .leading)

                // Trailing selection affordance, in a fixed slot so the hover icon swap never moves the text.
                trailingIndicator
                    .frame(width: 16, alignment: .center)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedBackground(backgroundColor, radius: NookTheme.Radius.control)
            .roundedStroke(borderColor, radius: NookTheme.Radius.control, lineWidth: isHovered || isPicked ? 1.2 : 1)
            .roundedHitShape(NookTheme.Radius.control)
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.pop()
                isHovered = false
            }
        }
        .animation(NookTheme.hover, value: isHovered)
        .animation(NookTheme.reveal, value: isPicked)
    }

    private var keycapBadge: some View {
        ZStack {
            NookTheme.shape(NookTheme.Radius.chip)
                .fill(isPicked ? NookTheme.amber.opacity(0.2) : (isHovered ? NookTheme.smoke : NookTheme.well))
            NookTheme.shape(NookTheme.Radius.chip)
                .stroke(isPicked ? NookTheme.amber.opacity(0.6) : (isHovered ? NookTheme.amber.opacity(0.4) : NookTheme.wash.opacity(0.08)), lineWidth: 1)

            Text(number < 9 ? "\(number + 1)" : "·")
                .font(NookTheme.mono(11, .semibold))
                .foregroundStyle(isPicked ? NookTheme.amber : (isHovered ? NookTheme.amber : NookTheme.textSecondary))
        }
        .frame(width: 20, height: 20)
        .padding(.top, 1)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if multiSelect {
            Image(icon: isPicked ? "checkmark.square.fill" : "square")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(isPicked ? NookTheme.amber : (isHovered ? NookTheme.paper : NookTheme.textTertiary))
                .padding(.top, 2)
        } else {
            Image(icon: isHovered ? "arrow.right.circle.fill" : "circle")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(isHovered ? NookTheme.amber : NookTheme.wash.opacity(0.08))
                .opacity(isHovered ? 1 : 0.4)
                .padding(.top, 3)
        }
    }

    private var backgroundColor: Color {
        if isPicked {
            return NookTheme.amber.opacity(0.12)
        } else if isHovered {
            return NookTheme.rowHover
        } else {
            return .clear
        }
    }

    private var borderColor: Color {
        isPicked ? NookTheme.amber.opacity(0.55) : .clear
    }
}

/// An answer in progress on one question.
private struct QuestionDraft: Equatable {
    var picks: Set<String>
    var own: String
}
