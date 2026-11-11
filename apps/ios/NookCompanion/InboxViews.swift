import SwiftUI
import UIKit

// MARK: The list

/// The Mac's Chats tab on the phone: WhatsApp (through the phone linked to Nook) and every other chat app Nook collects
/// on the Mac (Telegram, Messages, Slack…), newest first. A WhatsApp chat can be answered here; any other is read here
/// and answered in its own app.
struct InboxListView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var path: [String]
    @State private var query = ""
    @State private var filter = Filter.all

    /// All chats, or only the unread ones.
    enum Filter { case all, unread }

    private var shown: [InboxChatDigest] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return client.inbox.filter { chat in
            (filter != .unread || chat.unread > 0)
                && (words.isEmpty || chat.name.localizedCaseInsensitiveContains(words)
                    || chat.preview.localizedCaseInsensitiveContains(words) || chat.appName.localizedCaseInsensitiveContains(words))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PanelHeader()
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ConnectionLine()
                    if !client.can(CompanionFeature.inbox) {
                        WSEmptyState(symbol: "arrow.down.circle", title: String(localized: "Update Nook on your Mac"),
                                   message: String(localized: "Update Nook on your Mac to read and answer your chats from your phone."))
                    } else {
                        if client.inboxStatus == "chatsaccess" {
                            Banner(text: String(localized: "Nook cannot read the notifications on your Mac: give it Full Disk Access in System Settings."),
                                   symbol: "lock")
                        }
                        if client.inbox.isEmpty {
                            if client.phase == .connected {
                                if client.inboxStatus == "chatsoff" {
                                    WSEmptyState(symbol: "bubble.left.and.bubble.right", title: String(localized: "Chats are off on your Mac"),
                                               message: String(localized: "Link WhatsApp or turn on Chats in Nook › Settings › Connections to see every chat here."))
                                } else {
                                    WSEmptyState(symbol: "bubble.left.and.bubble.right", title: String(localized: "No chats yet"),
                                               message: String(localized: "New messages from WhatsApp and your other chat apps on your Mac show up here."))
                                }
                            }
                        } else {
                            // Finding one among many, as t3code's lists; only a very short list does without.
                            if client.inbox.count > 3 {
                                NookSearchField(prompt: "Search chats", text: $query)
                                HStack(spacing: Theme.Spacing.xs) {
                                    NookFilterChip(title: String(localized: "All"), selected: filter == .all) { filter = .all }
                                    NookFilterChip(title: String(localized: "Unread"), count: client.inbox.filter { $0.unread > 0 }.count, selected: filter == .unread) { filter = .unread }
                                }
                            }
                            if shown.isEmpty {
                                Group {
                                    switch filter {
                                    case .unread: Text("Nothing unread.")
                                    case .all: Text("No chat matches.")
                                    }
                                }
                                .multilineTextAlignment(.center)
                                .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xxl)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.md)
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, chat in
                        if index > 0 { NookRowSeparator() }
                        NavigationLink(value: chat.id) { InboxRow(chat: chat) }
                            .buttonStyle(RowPress(radius: PhoneRadius.row))
                            .contextMenu { markButton(chat) }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
            }
            .padding(.bottom, Theme.Spacing.xxl)
            // A chat that gets a message moves up instead of jumping there.
            .animation(Theme.reveal, value: client.inbox)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await client.loadInbox() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { InboxChatView(chatID: $0) }
        .screen()
        // The app's polling keeps the list current from here on (and the badge on the tab).
        .task { await client.loadInbox() }
    }

    /// Read or unread by hand, as the "…" menu of a chat on the Mac.
    @ViewBuilder
    private func markButton(_ chat: InboxChatDigest) -> some View {
        if chat.unread > 0 || chat.waitsInApp {
            Button { Task { await client.markInbox(chat.id, read: true) } } label: { Label("Mark as read", systemImage: "envelope.open") }
        } else {
            Button { Task { await client.markInbox(chat.id, read: false) } } label: { Label("Mark as unread", systemImage: "envelope.badge") }
        }
    }
}

/// A chat in the list: the shared row (`ChatListRowContent`, the same as the Mac's Chats tab) with the chat's initials
/// and its app's mark, and the count of what is unread.
struct InboxRow: View {
    let chat: InboxChatDigest
    @ObservedObject private var pictures = ChatPictures.shared

    private var when: String {
        let date = Date(timeIntervalSince1970: chat.last)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : ChatDayDivider.label(date)
    }

    var body: some View {
        ChatListRowContent(name: chat.name, when: when, preview: chat.preview.isEmpty ? chat.appName : chat.preview,
                           unread: chat.unread > 0, ticks: MessageTicks(chat.ticks),
                           // Someone typing shows in place of the newest message, as on the Mac and in WhatsApp's list.
                           typing: InboxTyping.text(chat.typing ?? [])) {
            InboxAvatar(name: chat.name, app: chat.app, size: SharedMetrics.avatar, picture: pictures.image(for: chat))
        } trailing: {
            NookCountBadge(count: chat.unread)
                .accessibilityLabel(Text("\(chat.unread) unread"))
        }
    }
}

/// A chat's initials in the person's own color (`ChatInitialsFace`, shared with the Mac), with its app's mark in the
/// app's own color in the corner.
struct InboxAvatar: View {
    let name: String
    let app: String
    var size: CGFloat = 40
    /// The chat's own picture from the Mac (`ChatPictures`); the initials while there is none.
    var picture: UIImage? = nil
    @ObservedObject private var pictures = ChatPictures.shared

    private var initials: String { Self.initials(name) }

    /// Up to two initials of a name ("#" when it has no letters), for a face without a photo.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        let letters = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }.map(String.init).joined()
        return letters.isEmpty ? "#" : letters.uppercased()
    }

    var body: some View {
        let style = Self.style(app)
        // The Mac's `ChatsAvatar`: the initials in the person's own color, the app as a badge on the corner.
        face
            .overlay(alignment: .bottomTrailing) {
                // The app's real icon from the Mac (the Mac's `SiteIcon` with `source`), else its mark in its color.
                Group {
                    if let icon = pictures.appIcon(app) {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: size * 0.46, height: size * 0.46)
                    } else {
                        Image(icon: style.symbol)
                            .font(Theme.font(size * 0.2, .bold))
                            .foregroundStyle(.white)
                            .frame(width: size * 0.42, height: size * 0.42)
                            .background(style.color, in: Circle())
                            .padding(Theme.Spacing.xxs / 2)
                            .background(Circle().fill(Theme.canvas))
                    }
                }
                .offset(x: Theme.Spacing.xs, y: Theme.Spacing.xxs)
            }
            .accessibilityHidden(true)
    }

    /// The photo when the Mac sent one, cut to a circle; else the initials in the person's own color.
    @ViewBuilder
    private var face: some View {
        if let picture {
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .transition(.opacity)
        } else {
            ChatInitialsFace(name: name, initials: initials, size: size)
        }
    }

    /// Each app in its own color, so a list of many apps reads at a glance.
    static func style(_ app: String) -> (symbol: String, color: Color) {
        switch app {
        case "whatsapp": return ("phone.fill", Color(hex: 0x25D366))
        case "telegram": return ("paperplane.fill", Color(hex: 0x2AABEE))
        case "messages": return ("message.fill", Color(hex: 0x34C759))
        case "signal": return ("bubble.left.fill", Color(hex: 0x3A76F0))
        case "instagram": return ("camera.fill", Color(hex: 0xE1306C))
        case "messenger": return ("bolt.horizontal.fill", Color(hex: 0x0084FF))
        case "snapchat": return ("camera.viewfinder", Color(hex: 0xF5C400))
        case "slack": return ("number", Color(hex: 0xE01E5A))
        case "discord": return ("gamecontroller.fill", Color(hex: 0x5865F2))
        case "teams": return ("person.3.fill", Color(hex: 0x6264A7))
        case "linkedin": return ("briefcase.fill", Color(hex: 0x0A66C2))
        case "mail": return ("envelope.fill", Color(hex: 0x1A8CFF))
        case "outlook": return ("envelope.badge.fill", Color(hex: 0x0078D4))
        case "gmail": return ("envelope.fill", Color(hex: 0xEA4335))
        default: return ("bubble.left.and.bubble.right.fill", Theme.textSecondary)
        }
    }
}

// MARK: One chat

struct InboxChatView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    let chatID: String
    @State private var text = ""
    @State private var sending = false
    /// The message the field answers, quoted above it until it is sent or let go.
    @State private var replyingTo: InboxLine?
    /// Your message whose info is open: who has it and who read it.
    @State private var info: InboxLine?

    @ObservedObject private var pictures = ChatPictures.shared
    private var chat: InboxChatDigest? { client.inbox.first { $0.id == chatID } }
    private var lines: [InboxLine] { client.inboxLines[chatID] ?? [] }
    /// Who is typing here now, as the Mac says it.
    private var typing: String? { InboxTyping.text(client.inboxTyping[chatID] ?? []) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if lines.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xxl)
                    }
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let previous = index > 0 ? lines[index - 1] : nil
                        let next = index + 1 < lines.count ? lines[index + 1] : nil
                        if ChatRuns.newDay(line, after: previous) { ChatDayDivider(date: Date(timeIntervalSince1970: line.date)) }
                        ChatBubbleView(line: line, first: !ChatRuns.sameRun(previous, line), last: !ChatRuns.sameRun(line, next),
                                       onInfo: line.readers?.isEmpty == false ? { info = line } : nil)
                            .contextMenu {
                                if chat?.canSend == true {
                                    Button { withAnimation { replyingTo = line } } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                                }
                                Button { UIPasteboard.general.string = line.text.isEmpty ? (line.attachment ?? "") : line.text } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                            }
                    }
                    if let typing {
                        ChatTypingBubble(text: typing).transition(.opacity)
                    }
                    // Your messages that wait on the phone for the Mac, dimmed, until it takes them.
                    let waiting = client.outbox.chatMessages(to: chatID)
                    ForEach(waiting) { entry in
                        ChatBubbleView(line: InboxLine(id: entry.id, text: entry.request.text ?? "", date: entry.queued, sender: "",
                                                       fromMe: true, reactions: []), pending: true)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.last?.id) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            // Someone starts typing: their bubble comes into view under the last message.
            .onChange(of: typing != nil) { _, shown in
                if shown { withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            }
            .animation(Theme.reveal, value: typing)
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // The chat's face beside its name, as a messaging app's header.
                HStack(spacing: Theme.Spacing.md) {
                    if let chat {
                        InboxAvatar(name: chat.name, app: chat.app, size: 30, picture: pictures.image(for: chat))
                    }
                    SheetTitle(title: chat?.name ?? "", subtitle: chat?.appName)
                }
            }
            if let chat {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if chat.unread > 0 || chat.waitsInApp {
                            Button { Task { await client.markInbox(chat.id, read: true) } } label: {
                                Label("Mark as read", systemImage: "envelope.open")
                            }
                        } else {
                            // As on the Mac, the chat closes, so that opening it again reads it.
                            Button {
                                Task {
                                    await client.markInbox(chat.id, read: false)
                                    dismiss()
                                }
                            } label: {
                                Label("Mark as unread", systemImage: "envelope.badge")
                            }
                        }
                    } label: {
                        Image(icon: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .screen()
        .sheet(item: $info) { line in
            InboxMessageInfo(line: line)
                .presentationDetents([.medium, .large])
        }
        .task(id: chatID) {
            // Live from a Mac that sends the open chat by itself (`liveChats`): new messages and typing show at once.
            // Otherwise, or while the connection is down, asked for every few seconds.
            while !Task.isCancelled {
                if client.chatsAreLive, await client.watchChat(chatID) {
                    while !Task.isCancelled, client.chatsAreLive { try? await Task.sleep(for: .seconds(2)) }
                    continue
                }
                await client.loadInboxChat(chatID)
                // While someone types, sooner: their words and the end of their typing show without a long wait.
                try? await Task.sleep(for: .seconds(typing == nil ? 4 : 1.5))
            }
        }
        .onDisappear { Task { await client.unwatchChat(chatID) } }
    }

    private static let bottom = "bottom"

    /// A WhatsApp chat gets the Mac's composer to answer, with the message it answers in a tray above it; any other
    /// chat says where to answer it.
    @ViewBuilder
    private var footer: some View {
        if chat?.canSend == true {
            ComposerDock {
                VStack(spacing: 0) {
                    if let replyingTo {
                        ComposerTray(edge: .top) {
                            HStack(spacing: Theme.Spacing.md) {
                                Capsule().fill(replyingTo.fromMe ? Theme.mint : Theme.blue).frame(width: 3)
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(replyingTo.fromMe ? String(localized: "You") : (replyingTo.sender.isEmpty ? chat?.name ?? "" : replyingTo.sender))
                                        .font(Theme.TextStyle.label).foregroundStyle(replyingTo.fromMe ? Theme.mint : Theme.blue)
                                    Text(replyingTo.text.isEmpty ? (replyingTo.attachment ?? "") : replyingTo.text)
                                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Button { withAnimation(Theme.reveal) { self.replyingTo = nil } } label: {
                                    Image(icon: "xmark").font(Theme.font(11, .bold)).foregroundStyle(Theme.textTertiary)
                                        .frame(width: 28, height: 28).contentShape(Rectangle())
                                }
                                .accessibilityLabel("Cancel reply")
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    SessionComposer(text: $text, prompt: "Message", sending: sending) {
                        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = ""
                        send(message)
                    }
                    .zIndex(1)
                }
            }
        } else if let chat {
            ComposerDock {
                Label {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Nook can only read this chat. Answer it in \(chat.appName).")
                        // How to answer it from here next time.
                        Text("To answer from your phone, link \(chat.appName) in Nook › Settings › Chats on your Mac.")
                            .foregroundStyle(Theme.textTertiary)
                    }
                } icon: {
                    Image(icon: "info.circle")
                }
                .font(Theme.TextStyle.detail)
                .foregroundStyle(Theme.textSecondary)
                .card(padding: Theme.Spacing.lg)
            }
        }
    }

    /// Your own words, after your own tap; when they could not go the text and the quote stay.
    private func send(_ message: String) {
        sending = true
        Haptics.tap()
        let quoted = replyingTo?.id
        Task {
            switch await client.sendInbox(message, to: chatID, replyTo: quoted) {
            case .sent:
                Haptics.success()
                if replyingTo?.id == quoted { replyingTo = nil }
                await client.loadInboxChat(chatID)
            case .waiting:
                // Kept on the phone, shown below as waiting, and sent once the Mac answers.
                if replyingTo?.id == quoted { replyingTo = nil }
            case .refused:
                text = message
            }
            sending = false
        }
    }
}

// MARK: Typing and message info

/// What a chat shows while people type, in the same words as the Mac's (`ChatTypingLine`).
enum InboxTyping {
    static func text(_ typists: [InboxTypist]) -> String? {
        guard let first = typists.first else { return nil }
        let names = typists.map(\.name).filter { !$0.isEmpty }
        if typists.count > 2 { return String(localized: "\(typists.count) people are typing…") }
        if typists.count == 2, names.count == 2 { return String(localized: "\(names[0]) and \(names[1]) are typing…") }
        let who = names.first
        switch first.kind {
        case "recording": return who.map { String(localized: "\($0) is recording audio…") } ?? String(localized: "recording audio…")
        case "uploading": return who.map { String(localized: "\($0) is sending a file…") } ?? String(localized: "sending a file…")
        default: return who.map { String(localized: "\($0) is typing…") } ?? String(localized: "typing…")
        }
    }
}

/// Your message's info, as on the Mac: how many read it, then who read it (and when), who has it, and who does not yet.
struct InboxMessageInfo: View {
    let line: InboxLine

    private var readers: [InboxReader] { line.readers ?? [] }
    private var read: [InboxReader] { readers.filter { $0.receipt == "read" } }
    private var delivered: [InboxReader] { readers.filter { $0.receipt == "delivered" } }
    private var waiting: [InboxReader] { readers.filter { $0.receipt != "read" && $0.receipt != "delivered" } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(line.text.isEmpty ? (line.attachment ?? "") : line.text)
                        .font(Theme.TextStyle.body).foregroundStyle(Theme.paper).lineLimit(4)
                } footer: {
                    Text("\(read.count) of \(readers.count) have read it")
                }
                section("Read by", read, ticks: "read")
                section("Delivered to", delivered, ticks: "delivered")
                section("Not yet", waiting, ticks: "sent")
            }
            .navigationTitle(Text("Message info"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ people: [InboxReader], ticks: String) -> some View {
        if !people.isEmpty {
            Section {
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    HStack {
                        Text(person.name).font(Theme.TextStyle.body).foregroundStyle(Theme.paper).lineLimit(1)
                        Spacer(minLength: Theme.Spacing.md)
                        if let date = person.date {
                            Text(Date(timeIntervalSince1970: date), format: .dateTime.weekday(.abbreviated).hour().minute())
                                .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack(spacing: Theme.Spacing.xs) {
                    MessageTicksMark(ticks: MessageTicks(ticks) ?? .sent)
                    Text(title)
                }
            }
        }
    }
}
