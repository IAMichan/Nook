import SwiftUI

/// What you can do with one mail in the mail view.
enum MailThreadAction {
    /// Answer the one who wrote it, in the field under the conversation.
    case reply
    /// Answer everyone it went to, in a new mail.
    case replyAll
    case forward
    /// Open it in Mail itself (the app, for a mail app Nook only knows by its notifications).
    case openInMail
}

/// A conversation in a mail app as mail reads, not as chat bubbles: the subject on top, then every mail as a card, oldest
/// first. The newest mail and the ones still unread are open; the others fold to one line (who, the start of the text,
/// when) and open with a click. An open mail shows who wrote it to whom, when, its attachments and its whole text, read
/// from Mail as it opens (`load`), with the mail it quotes folded away. Under the pointer it offers to answer, answer
/// everyone, forward, or open it in Mail. The Chats tab draws every chat of a mail app (`MailChatData.apps`) with it;
/// never draw mail as bubbles.
struct MailThreadView: View {
    let messages: [InboxMessage]
    /// The other person, as the chat is named.
    let contact: String
    /// The account the conversation is in, while there is more than one; nil otherwise.
    var account: String?
    /// How many mails at the end are new: they open too.
    var unread: Int = 0
    /// Reads a mail whole from Mail by its id in Nook; nil for a mail app Nook only knows by its notifications.
    var load: ((String) async throws -> MailChatData.Message)?
    var onAction: (MailThreadAction, InboxMessage, MailChatData.Message?) -> Void

    @State private var open: Set<String> = []
    @State private var loaded: [String: MailChatData.Message] = [:]
    /// Why a mail could not come from Mail, by its id: the card says so and offers to try again, instead of loading on.
    @State private var failed: [String: String] = [:]
    /// Each "Try again" asks Mail once more.
    @State private var attempts: [String: Int] = [:]
    @State private var placed = false

    /// The subject the conversation is about: the newest mail's, without "Re:" and the like.
    private var subject: String {
        let newest = messages.last.map { MailChatData.parts($0.text).subject } ?? ""
        let plain = Self.bareSubject(newest)
        return plain.isEmpty ? tr("chats.mail.noSubject") : plain
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    header
                        .padding(.bottom, NookTheme.Spacing.sm)
                    ForEach(messages) { message in
                        MailMessageCard(message: message, contact: contact, whole: loaded[message.id],
                                        isOpen: open.contains(message.id), canLoad: load != nil,
                                        failure: failed[message.id],
                                        onToggle: { toggle(message) },
                                        onRetry: { retry(message) },
                                        onAction: { onAction($0, message, loaded[message.id]) })
                            .id(message.id)
                            .task(id: "\(open.contains(message.id)) \(attempts[message.id] ?? 0)") { await read(message) }
                    }
                }
                .padding(.vertical, NookTheme.Spacing.lg)
                .chatColumn()
            }
            .scrollIndicators(.automatic)
            .onAppear {
                openNewest()
                guard !placed, let last = messages.last else { return }
                placed = true
                // The newest mail from its top, as a mail app opens a conversation.
                DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .top) }
            }
            .onChange(of: messages.last?.id) { _, newest in
                guard let newest else { return }
                open.insert(newest)
                withAnimation(NookTheme.scroll) { proxy.scrollTo(newest, anchor: .top) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Text(subject)
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text([messages.count == 1 ? nil : tr("chats.mail.count", messages.count), account]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
        }
        .padding(.horizontal, NookTheme.Spacing.xs)
    }

    /// The newest mail and the new ones are open when the conversation opens.
    private func openNewest() {
        guard open.isEmpty else { return }
        if let last = messages.last { open.insert(last.id) }
        let incoming = messages.filter { !$0.isMine }
        for message in incoming.suffix(unread) { open.insert(message.id) }
    }

    private func toggle(_ message: InboxMessage) {
        withAnimation(NookTheme.reveal) {
            if open.contains(message.id) { open.remove(message.id) } else { open.insert(message.id) }
        }
    }

    /// An open mail is read whole from Mail, once.
    private func read(_ message: InboxMessage) async {
        guard open.contains(message.id), loaded[message.id] == nil, failed[message.id] == nil, let load else { return }
        do {
            loaded[message.id] = try await load(message.id)
        } catch {
            guard !Task.isCancelled else { return }
            failed[message.id] = error.localizedDescription
        }
    }

    private func retry(_ message: InboxMessage) {
        failed[message.id] = nil
        attempts[message.id, default: 0] += 1
    }

    /// "Re: Fwd: Offerte" → "Offerte".
    static func bareSubject(_ subject: String) -> String {
        var rest = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["re:", "aw:", "antw:", "sv:", "fwd:", "fw:", "wg:", "doorst:", "tr:", "rv:"]
        while let prefix = prefixes.first(where: { rest.lowercased().hasPrefix($0) }) {
            rest = rest.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return rest
    }
}

/// One mail in `MailThreadView`: folded to a line, or open with its headers, attachments and text.
struct MailMessageCard: View {
    let message: InboxMessage
    let contact: String
    /// The whole mail once Mail gave it; until then the start of its text the conversation keeps.
    let whole: MailChatData.Message?
    let isOpen: Bool
    /// The whole mail can come from Mail: until it does, a spinner where its text has nothing yet.
    var canLoad = true
    /// Why the whole mail did not come from Mail; nil while it comes or came.
    var failure: String? = nil
    let onToggle: () -> Void
    var onRetry: () -> Void = {}
    let onAction: (MailThreadAction) -> Void

    @State private var hovering = false
    @State private var showsQuoted = false

    private var sender: String {
        if message.isMine { return tr("chats.mail.me") }
        if let from = whole?.from, !from.isEmpty { return MailChatData.name(from) }
        return contact
    }

    private var address: String {
        if let from = whole?.from { return MailChatData.address(from) }
        return message.isMine ? "" : (message.senderID ?? "")
    }

    private var text: (own: String, quoted: String) {
        if let whole { return MailChatData.split(whole.body) }
        return (MailChatData.parts(message.text).body, "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            if isOpen {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    if let whole, !whole.attachments.isEmpty { attachments(whole.attachments) }
                    content
                }
                .padding(.top, NookTheme.Spacing.md)
                .padding(.leading, 32 + NookTheme.Spacing.md)
                .transition(.opacity)
            }
        }
        .padding(NookTheme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
            .fill(isOpen ? NookTheme.field : NookTheme.rowFill(selected: false, hovering: hovering, rest: NookTheme.rowRest)))
        .contentShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .contextMenu { menu }
    }

    /// Who, to whom and when; folded, the start of the text instead. A click on it opens or folds the mail.
    private var top: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            ChatPersonBadge(name: sender, size: 32)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Text(sender)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if isOpen, !address.isEmpty, address != sender {
                        Text(address)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if isOpen && hovering { actions } else { date }
                }
                if isOpen {
                    recipients
                } else {
                    Text(snippet)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? tr("chats.mail.fold") : tr("chats.mail.unfold"))
    }

    private var snippet: String {
        let parts = MailChatData.parts(message.text)
        let body = ChatFormat.plain(parts.body).replacingOccurrences(of: "\n", with: " ")
        return body.isEmpty ? parts.subject : body
    }

    private var date: some View {
        Text(MailDates.short(message.date))
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .monospacedDigit()
            .help(MailDates.full(message.date))
    }

    /// "to Lisa, Bram · cc Anna": the names, the addresses in the tooltip.
    @ViewBuilder
    private var recipients: some View {
        let to = whole?.to ?? []
        let cc = whole?.cc ?? []
        let line = [to.isEmpty ? nil : tr("chats.mail.toLine", names(to)), cc.isEmpty ? nil : tr("chats.mail.ccLine", names(cc))]
            .compactMap { $0 }.joined(separator: " · ")
        if !line.isEmpty {
            Text(line)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(2)
                .help((to + cc).joined(separator: "\n"))
        } else {
            Text(MailDates.full(message.date))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
        }
    }

    private func names(_ people: [String]) -> String {
        people.map { MailChatData.name($0) }.joined(separator: ", ")
    }

    private var actions: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ToolbarIconButton("arrowshape.turn.up.left", tr("chats.mail.reply")) { onAction(.reply) }
            ToolbarIconButton("arrowshape.turn.up.left.2", tr("chats.mail.replyAll")) { onAction(.replyAll) }
            ToolbarIconButton("arrowshape.turn.up.right", tr("chats.mail.forward")) { onAction(.forward) }
            ToolbarIconButton("envelope", tr("button.openInMail")) { onAction(.openInMail) }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var menu: some View {
        Button(tr("chats.mail.reply")) { onAction(.reply) }
        Button(tr("chats.mail.replyAll")) { onAction(.replyAll) }
        Button(tr("chats.mail.forward")) { onAction(.forward) }
        Divider()
        Button(tr("button.copy")) { Pasteboard.copy(whole?.body ?? MailChatData.parts(message.text).body) }
        Button(tr("button.openInMail")) { onAction(.openInMail) }
    }

    /// The mail's own words, then the mail it quotes behind "Show quoted text".
    @ViewBuilder
    private var content: some View {
        let text = self.text
        if let failure, whole == nil { failureLine(failure) }
        if text.own.isEmpty, text.quoted.isEmpty {
            if whole == nil, canLoad, failure == nil { PatientSpinner().frame(height: 40) } else if failure == nil {
                Text(tr("chats.mail.empty"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        } else {
            if !text.own.isEmpty { ChatMessageText(text: text.own) }
            if !text.quoted.isEmpty {
                Button {
                    withAnimation(NookTheme.reveal) { showsQuoted.toggle() }
                } label: {
                    Label(showsQuoted ? tr("chats.mail.hideQuoted") : tr("chats.mail.showQuoted"), systemImage: "ellipsis")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .padding(.horizontal, NookTheme.Spacing.sm)
                        .padding(.vertical, NookTheme.Spacing.xxs)
                        .background(Capsule().fill(NookTheme.smoke))
                }
                .buttonStyle(.plain)
                if showsQuoted {
                    ChatMessageText(text: text.quoted)
                        .opacity(0.75)
                        .transition(.opacity)
                }
            }
        }
    }

    /// The whole mail did not come: why, and what to do about it. The start of its text, when the conversation has it,
    /// still shows under it.
    private func failureLine(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(reason)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NookTheme.Spacing.sm) {
                SmallGhostButton(title: tr("chats.mail.tryAgain"), action: onRetry)
                SmallGhostButton(title: tr("button.openInMail")) { onAction(.openInMail) }
            }
        }
    }

    private func attachments(_ names: [String]) -> some View {
        ChipFlow {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "paperclip")
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.vertical, NookTheme.Spacing.xs)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.smoke))
                    .help(tr("chats.mail.attachmentInMail"))
            }
        }
    }
}

/// When a mail came, the way mail apps say it: the time today, the weekday this week, the day and month this year,
/// and the year before that; in full in a tooltip.
@MainActor
enum MailDates {
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let template: String
        if calendar.isDate(date, inSameDayAs: now) {
            template = "jmm"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                     to: calendar.startOfDay(for: now)).day, days < 7, days >= 0 {
            template = "EEEjmm"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            template = "dMMM"
        } else {
            template = "dMMMyyyy"
        }
        return formatter(template).string(from: date)
    }

    static func full(_ date: Date) -> String {
        formatter("EEEEdMMMMyyyyjmm").string(from: date)
    }

    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ template: String) -> DateFormatter {
        // In the language Nook speaks, made again when that changes.
        let language = I18n.shared.currentLanguage.rawValue
        let key = language + "|" + template
        if let kept = formatters[key] { return kept }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter
    }
}
