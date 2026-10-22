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
    @State private var unreadOnly = false

    private var shown: [InboxChatDigest] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return client.inbox.filter { chat in
            (!unreadOnly || chat.unread > 0)
                && (words.isEmpty || chat.name.localizedCaseInsensitiveContains(words)
                    || chat.preview.localizedCaseInsensitiveContains(words) || chat.appName.localizedCaseInsensitiveContains(words))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if !client.can(CompanionFeature.inbox) {
                    EmptyState(symbol: "arrow.down.circle", title: "Update Nook on your Mac",
                               message: "Update Nook on your Mac to read and answer your chats from your phone.") {}
                } else {
                    if client.inboxStatus == "chatsaccess" {
                        Banner(text: String(localized: "Nook cannot read the notifications on your Mac: give it Full Disk Access in System Settings."),
                               symbol: "lock")
                    }
                    if client.inbox.isEmpty {
                        if client.phase == .connected {
                            if client.inboxStatus == "chatsoff" {
                                EmptyState(symbol: "bubble.left.and.bubble.right", title: "Chats are off on your Mac",
                                           message: "Link WhatsApp or turn on Chats in Nook › Settings › Chats to see every chat here.") {}
                            } else {
                                EmptyState(symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                                           message: "New messages from WhatsApp and your other chat apps on your Mac show up here.") {}
                            }
                        }
                    } else {
                        Picker("Show", selection: $unreadOnly) {
                            Text("All").tag(false)
                            Text("Unread").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if shown.isEmpty {
                            Group {
                                if unreadOnly { Text("Nothing unread.") } else { Text("No chat matches.") }
                            }
                            .font(.callout).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xl)
                        }
                        ForEach(shown) { chat in
                            NavigationLink(value: chat.id) { InboxRow(chat: chat) }
                                .buttonStyle(.plain)
                                .contextMenu { markButton(chat) }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .searchable(text: $query, prompt: Text("Search chats"))
        .refreshable { await client.loadInbox() }
        .navigationTitle("Chats")
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

struct InboxRow: View {
    let chat: InboxChatDigest

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            InboxAvatar(name: chat.name, app: chat.app)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: Theme.Spacing.sm)
                    Text(Date(timeIntervalSince1970: chat.last), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.caption2).foregroundStyle(chat.unread > 0 ? Theme.iris : Theme.textTertiary)
                }
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    HStack(spacing: 4) {
                        if let ticks = chat.ticks { TicksMark(ticks: ticks) }
                        Text(chat.preview.isEmpty ? chat.appName : chat.preview)
                            .font(.subheadline).foregroundStyle(chat.unread > 0 ? Theme.text : Theme.textSecondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if chat.unread > 0 {
                        Text(chat.unread, format: .number)
                            .font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.iris, in: Capsule())
                            .accessibilityLabel(Text("\(chat.unread) unread"))
                    }
                }
                Text(chat.appName).font(.caption2.weight(.medium)).foregroundStyle(Theme.textTertiary)
            }
        }
        .card(padding: Theme.Spacing.md)
        .contentShape(Rectangle())
    }
}

/// A chat's initials on its app's color, with the app's mark in the corner.
struct InboxAvatar: View {
    let name: String
    let app: String
    var size: CGFloat = 40

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        let letters = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }.map(String.init).joined()
        return letters.isEmpty ? "#" : letters.uppercased()
    }

    var body: some View {
        let style = Self.style(app)
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
            .foregroundStyle(style.color)
            .frame(width: size, height: size)
            .background(style.color.opacity(0.16), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(style.color, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
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
        case "slack": return ("number", Color(hex: 0xE01E5A))
        case "discord": return ("gamecontroller.fill", Color(hex: 0x5865F2))
        case "teams": return ("person.3.fill", Color(hex: 0x6264A7))
        case "linkedin": return ("briefcase.fill", Color(hex: 0x0A66C2))
        default: return ("bubble.left.and.bubble.right.fill", Theme.iris)
        }
    }
}

/// How far your own message got, as WhatsApp shows it.
struct TicksMark: View {
    let ticks: String

    var body: some View {
        Group {
            switch ticks {
            case "pending": Image(systemName: "clock").foregroundStyle(Theme.textTertiary)
            case "sent": Image(systemName: "checkmark").foregroundStyle(Theme.textTertiary)
            case "delivered": Image(systemName: "checkmark.circle").foregroundStyle(Theme.textTertiary)
            case "read": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.iris)
            default: Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.coral)
            }
        }
        .font(.caption2.weight(.semibold))
        .accessibilityLabel(Self.label(ticks))
    }

    static func label(_ ticks: String) -> String {
        switch ticks {
        case "pending": return String(localized: "Sending")
        case "sent": return String(localized: "Sent")
        case "delivered": return String(localized: "Delivered")
        case "read": return String(localized: "Read")
        default: return String(localized: "Not sent")
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

    private var chat: InboxChatDigest? { client.inbox.first { $0.id == chatID } }
    private var lines: [InboxLine] { client.inboxLines[chatID] ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    if lines.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xl)
                    }
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let previous = index > 0 ? lines[index - 1] : nil
                        if Self.newDay(line, after: previous) { DayLine(date: Date(timeIntervalSince1970: line.date)) }
                        InboxBubble(line: line, showsSender: previous?.sender != line.sender || previous?.fromMe != line.fromMe)
                            .contextMenu {
                                if chat?.canSend == true {
                                    Button { withAnimation { replyingTo = line } } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                                }
                                Button { UIPasteboard.general.string = line.text.isEmpty ? (line.attachment ?? "") : line.text } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                            }
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.last?.id) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .navigationTitle(chat?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .screen()
        .task(id: chatID) {
            while !Task.isCancelled {
                await client.loadInboxChat(chatID)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private static let bottom = "bottom"

    /// A WhatsApp chat gets the field to answer; any other says where to answer it.
    @ViewBuilder
    private var footer: some View {
        if chat?.canSend == true {
            VStack(spacing: 0) {
                if let replyingTo {
                    HStack(spacing: Theme.Spacing.sm) {
                        Rectangle().fill(Theme.iris).frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(replyingTo.fromMe ? String(localized: "You") : (replyingTo.sender.isEmpty ? chat?.name ?? "" : replyingTo.sender))
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.iris)
                            Text(replyingTo.text.isEmpty ? (replyingTo.attachment ?? "") : replyingTo.text)
                                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button { withAnimation { self.replyingTo = nil } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                        }
                        .accessibilityLabel("Cancel reply")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.surface)
                }
                ComposerBar(placeholder: "Message", text: $text, busy: sending) { message in send(message) }
                    .disabled(sending)
            }
        } else if let chat {
            Label {
                Text("Nook can only read this chat. Answer it in \(chat.appName).")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .background(Theme.canvas.opacity(0.96))
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    /// Your own words, after your own tap; when they could not go the text and the quote stay.
    private func send(_ message: String) {
        sending = true
        Haptics.tap()
        let quoted = replyingTo?.id
        Task {
            if await client.sendInbox(message, to: chatID, replyTo: quoted) {
                Haptics.success()
                if replyingTo?.id == quoted { replyingTo = nil }
                await client.loadInboxChat(chatID)
            } else {
                text = message
            }
            sending = false
        }
    }

    private static func newDay(_ line: InboxLine, after previous: InboxLine?) -> Bool {
        guard let previous else { return true }
        return !Calendar.current.isDate(Date(timeIntervalSince1970: line.date), inSameDayAs: Date(timeIntervalSince1970: previous.date))
    }
}

/// Where a new day starts in a chat.
private struct DayLine: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.weekday(.wide).day().month())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.raised, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.sm)
    }
}

/// A message: yours in an iris bubble on the right, theirs on the left with who wrote it in a group.
struct InboxBubble: View {
    let line: InboxLine
    let showsSender: Bool

    var body: some View {
        HStack {
            if line.fromMe { Spacer(minLength: 48) }
            VStack(alignment: line.fromMe ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if showsSender, !line.fromMe, !line.sender.isEmpty {
                        Text(line.sender).font(.caption.weight(.semibold)).foregroundStyle(Theme.mint)
                    }
                    if let quote = line.quoteText, !quote.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            if let sender = line.quoteSender, !sender.isEmpty {
                                Text(sender).font(.caption2.weight(.semibold))
                            }
                            Text(quote).font(.caption).lineLimit(3)
                        }
                        .foregroundStyle(line.fromMe ? .white.opacity(0.85) : Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background((line.fromMe ? Color.white : Theme.iris).opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    }
                    if let attachment = line.attachment {
                        Label(attachment, systemImage: "paperclip")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(line.fromMe ? .white : Theme.iris)
                    }
                    if !line.text.isEmpty {
                        Text(verbatim: line.text)
                            .font(.body)
                            .foregroundStyle(line.fromMe ? .white : Theme.text)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 4) {
                        Text(Date(timeIntervalSince1970: line.date), format: .dateTime.hour().minute())
                        if let ticks = line.ticks { TicksMark(ticks: ticks) }
                    }
                    .font(.caption2)
                    .foregroundStyle(line.fromMe ? .white.opacity(0.75) : Theme.textTertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(line.fromMe ? Theme.iris : Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .overlay {
                    if !line.fromMe {
                        RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous).strokeBorder(Theme.hairline)
                    }
                }
                if !line.reactions.isEmpty {
                    Text(line.reactions.joined(separator: "  "))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.raised, in: Capsule())
                }
            }
            if !line.fromMe { Spacer(minLength: 48) }
        }
    }
}
