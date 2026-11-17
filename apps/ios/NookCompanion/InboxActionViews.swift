import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// What the Chats tab on the phone does besides reading and answering, as the Mac's Chats tab does it
// (`CompanionFeature.chatActions`): the chat's own actions, emoji, polls, forwarding, a chat's info, photos full screen,
// and pictures and files with your words. Each is offered only where the chat's app takes it (`InboxChatDigest.abilities`).

extension InboxChatDigest {
    /// What can be done in it, as its Mac says (`InboxAbility`); nothing from a Mac without `chatActions`.
    var can: Set<InboxAbility> { InboxAbility.parse(abilities) }
    /// Which list it shows in: chats, status updates or channels.
    var listKind: String { kind ?? "chats" }
}

/// The quick emoji the Mac's message menu offers first, in the same order (`ChatTranscript`).
enum InboxQuickReactions {
    static let all = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
}

// MARK: The chat's own actions

/// The chat's own actions, the same in the row's menu, its swipe and the chat's "…" menu, as the Mac's
/// (`ChatAppActions`): read state, pinning in Nook and in its app, muting, archiving, removing and deleting it.
/// Destructive ones ask first through `confirm`.
struct InboxChatActions: View {
    @EnvironmentObject private var client: CompanionClient
    let chat: InboxChatDigest
    /// Asks before removing or deleting the chat (`InboxConfirm`).
    let confirm: (InboxConfirm) -> Void
    /// The chat closes after "Mark as unread", so that opening it again reads it, as on the Mac.
    var onUnread: (() -> Void)? = nil

    var body: some View {
        let can = chat.can
        Section {
            if chat.unread > 0 {
                Button { act(.init(kind: .markReadInNook)) } label: { Label("Mark as read in Nook", systemImage: "checkmark.circle") }
            }
            if (chat.unread > 0 || chat.waitsInApp), can.contains(.markReadInApp) {
                Button { act(.init(kind: .markReadInApp)) } label: {
                    Label("Mark as read in \(chat.appName)", systemImage: "envelope.open")
                }
            }
            if chat.unread == 0 {
                Button {
                    act(.init(kind: .markUnread))
                    onUnread?()
                } label: { Label("Mark as unread", systemImage: "envelope.badge") }
            }
        }
        Section {
            let pinned = chat.pinned == true
            Button { act(.init(kind: .pin, value: !pinned)) } label: {
                Label(pinned ? "Unpin in Nook" : "Pin in Nook", systemImage: pinned ? "pin.slash" : "pin")
            }
            if can.contains(.pinInApp) {
                let inApp = chat.pinnedInApp == true
                Button { act(.init(kind: .pinInApp, value: !inApp)) } label: {
                    Label(inApp ? "Unpin in \(chat.appName)" : "Pin in \(chat.appName)", systemImage: inApp ? "pin.slash.fill" : "pin.fill")
                }
            }
            if can.contains(.muteInApp) {
                let muted = chat.mutedInApp == true
                Button { act(.init(kind: .muteInApp, value: !muted)) } label: {
                    Label(muted ? "Unmute in \(chat.appName)" : "Mute in \(chat.appName)", systemImage: muted ? "bell" : "bell.slash")
                }
            }
            if can.contains(.archive) {
                Button { act(.init(kind: .archive)) } label: { Label("Archive in \(chat.appName)", systemImage: "archivebox") }
            }
        }
        if let link = InboxAppLink.open(chat) {
            Button { UIApplication.shared.open(link) } label: {
                Label("Open in \(chat.appName)", systemImage: "arrow.up.forward.app")
            }
        }
        Section {
            Button(role: .destructive) { confirm(.remove(chat)) } label: { Label("Remove from Nook", systemImage: "eye.slash") }
            if can.contains(.deleteChat) {
                Button(role: .destructive) { confirm(.deleteChat(chat)) } label: {
                    Label("Delete in \(chat.appName)", systemImage: "trash")
                }
            }
        }
    }

    private func act(_ action: InboxAction) {
        Haptics.tap()
        Task { await client.actInInbox(chat.id, action) }
    }
}

/// What asks first before it goes: removing a chat from Nook, deleting it in its app, deleting a message.
enum InboxConfirm: Identifiable {
    case remove(InboxChatDigest)
    case deleteChat(InboxChatDigest)
    case deleteMessage(InboxChatDigest, InboxLine)

    var id: String {
        switch self {
        case .remove(let chat): return "remove|" + chat.id
        case .deleteChat(let chat): return "delete|" + chat.id
        case .deleteMessage(let chat, let line): return "message|" + chat.id + "|" + line.id
        }
    }
}

extension View {
    /// The question before a chat or a message goes, with what each choice does, as on the Mac.
    func inboxConfirm(_ item: Binding<InboxConfirm?>, client: CompanionClient, onGone: (() -> Void)? = nil) -> some View {
        confirmationDialog(Self.confirmTitle(item.wrappedValue), isPresented: Binding(get: { item.wrappedValue != nil },
                                                                                       set: { if !$0 { item.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: item.wrappedValue) { confirm in
            switch confirm {
            case .remove(let chat):
                Button("Remove from Nook", role: .destructive) {
                    Task { if await client.actInInbox(chat.id, .init(kind: .remove)) { onGone?() } }
                }
            case .deleteChat(let chat):
                Button("Delete in \(chat.appName)", role: .destructive) {
                    Task { if await client.actInInbox(chat.id, .init(kind: .deleteChat)) { onGone?() } }
                }
            case .deleteMessage(let chat, let line):
                if line.fromMe, chat.can.contains(.delete), line.deleted != true {
                    Button("Delete for everyone", role: .destructive) {
                        Task { await client.actInInbox(chat.id, .init(kind: .delete, message: line.id)) }
                    }
                }
                Button("Delete for me", role: .destructive) {
                    Task { await client.actInInbox(chat.id, .init(kind: .deleteForMe, message: line.id)) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirm in
            switch confirm {
            case .remove:
                Text("It leaves Nook's Chats until a new message comes in. Nothing changes in the app itself.")
            case .deleteChat(let chat):
                Text("The chat is deleted in \(chat.appName) for you; a group you also leave. This cannot be undone.")
            case .deleteMessage(let chat, let line):
                if line.fromMe, chat.can.contains(.delete), line.deleted != true {
                    if chat.can.contains(.deleteForMe) {
                        Text("For me: gone from Nook and from \(chat.appName). For everyone: deleted in \(chat.appName) for everyone in the chat.")
                    } else {
                        Text("For me: gone from Nook. For everyone: deleted in \(chat.appName) for everyone in the chat.")
                    }
                } else if chat.can.contains(.deleteForMe) {
                    Text("Gone from Nook and from \(chat.appName), for you.")
                } else {
                    Text("Gone from Nook. It stays in \(chat.appName).")
                }
            }
        }
    }

    private static func confirmTitle(_ confirm: InboxConfirm?) -> Text {
        switch confirm {
        case .remove(let chat)?: return Text("Remove \(chat.name) from Nook?")
        case .deleteChat(let chat)?: return Text("Delete \(chat.name) in \(chat.appName)?")
        case .deleteMessage?: return Text("Delete this message?")
        case nil: return Text(verbatim: "")
        }
    }
}

// MARK: Polls

/// A poll in a bubble, as the Mac's `ChatPollView`: each option with its share, yours marked, a tap votes where the chat's
/// app takes it.
struct InboxPollView: View {
    let poll: InboxPoll
    var onVote: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Image(icon: "chart.bar.fill").font(Theme.font(13)).foregroundStyle(Theme.textSecondary)
                Text(verbatim: poll.question).font(Theme.TextStyle.body.weight(.semibold)).foregroundStyle(Theme.paper)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(poll.multiple ? "Choose one or more" : "Choose one")
                .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            ForEach(poll.options) { option in
                Button {
                    guard onVote != nil else { return }
                    Haptics.tap()
                    onVote?(option.text)
                } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(icon: option.chosen ? (poll.multiple ? "checkmark.square.fill" : "checkmark.circle.fill")
                                  : (poll.multiple ? "square" : "circle"))
                                .font(Theme.font(15))
                                .foregroundStyle(option.chosen ? Theme.mint : Theme.textTertiary)
                            Text(verbatim: option.text).font(Theme.TextStyle.body).foregroundStyle(Theme.paper)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: Theme.Spacing.md)
                            if poll.counted {
                                Text(verbatim: "\(option.votes)").font(Theme.TextStyle.caption).monospacedDigit()
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        if poll.counted {
                            GeometryReader { proxy in
                                Capsule().fill(Theme.smoke)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(option.chosen ? Theme.mint : Theme.textTertiary)
                                            .frame(width: proxy.size.width * share(option))
                                    }
                            }
                            .frame(height: 4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onVote == nil)
                .accessibilityValue(option.chosen ? Text("Chosen") : Text(verbatim: ""))
            }
            if onVote == nil {
                Text("Vote in its own app.").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    private func share(_ option: InboxPoll.Option) -> CGFloat {
        let total = poll.total
        return total == 0 ? 0 : CGFloat(option.votes) / CGFloat(total)
    }
}

// MARK: Emoji

/// Every emoji to react with, beyond the quick ones: a few rows of the common ones, as a sheet.
struct InboxReactionPicker: View {
    let current: Set<String>
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let emoji = ["👍", "👎", "❤️", "🔥", "😂", "🤣", "😊", "😍", "🥰", "😘", "😮", "😯", "😢", "😭", "😡", "🙏",
                                "👏", "🙌", "💪", "🤝", "👌", "✌️", "🤞", "👀", "🎉", "🥳", "💯", "✅", "❌", "⭐️", "🤔", "🙈",
                                "😅", "😬", "🤯", "😴", "🤗", "😎", "🤩", "😇", "💜", "💙", "💚", "💛", "🧡", "🖤", "🤍", "💔"]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.sm), count: 8), spacing: Theme.Spacing.md) {
                    ForEach(Self.emoji, id: \.self) { emoji in
                        Button {
                            Haptics.tap()
                            onPick(emoji)
                            dismiss()
                        } label: {
                            Text(verbatim: emoji).font(Theme.font(28))
                                .frame(width: 40, height: 40)
                                .background(current.contains(emoji) ? Theme.smoke : .clear, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
            .navigationTitle(Text("React"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: Forwarding

/// The Mac's forward picker on the phone: every chat Nook can write in, searchable, more than one at a time.
struct InboxForwardSheet: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    let chatID: String
    let line: InboxLine
    @State private var query = ""
    @State private var chosen: Set<String> = []
    @State private var sending = false
    @ObservedObject private var pictures = ChatPictures.shared

    private var targets: [InboxChatDigest] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return client.inbox.filter { chat in
            chat.canSend && chat.listKind == "chats"
                && (words.isEmpty || chat.name.localizedCaseInsensitiveContains(words) || chat.appName.localizedCaseInsensitiveContains(words))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(verbatim: line.text.isEmpty ? (line.attachment ?? "") : line.text)
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
                Section {
                    ForEach(targets) { chat in
                        Button {
                            Haptics.tap()
                            if chosen.contains(chat.id) { chosen.remove(chat.id) }
                            else if chosen.count < InboxAction.maxTargets { chosen.insert(chat.id) }
                        } label: {
                            HStack(spacing: Theme.Spacing.lg) {
                                InboxAvatar(name: chat.name, app: chat.app, size: 34, picture: pictures.image(for: chat))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: chat.name).font(Theme.TextStyle.body).foregroundStyle(Theme.paper).lineLimit(1)
                                    Text(verbatim: chat.appName).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                                }
                                Spacer(minLength: Theme.Spacing.md)
                                Image(icon: chosen.contains(chat.id) ? "checkmark.circle.fill" : "circle")
                                    .font(Theme.font(20))
                                    .foregroundStyle(chosen.contains(chat.id) ? Theme.iris : Theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: Text("Search chats"))
            .navigationTitle(Text("Forward to"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        sending = true
                        Task {
                            if await client.actInInbox(chatID, .init(kind: .forward, message: line.id, targets: Array(chosen))) {
                                Haptics.success()
                                dismiss()
                            }
                            sending = false
                        }
                    } label: {
                        if sending { ProgressView() } else { Text(chosen.count > 1 ? "Send to \(chosen.count)" : "Send") }
                    }
                    .disabled(chosen.isEmpty || sending)
                }
            }
        }
    }
}

// MARK: Editing

/// Your own message's new words, as the Mac's "Edit": a sheet with its text to change.
struct InboxEditSheet: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    let chatID: String
    let line: InboxLine
    @State private var text = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(2...12)
                    .focused($focused)
            }
            .navigationTitle(Text("Edit message"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            if await client.actInInbox(chatID, .init(kind: .edit, message: line.id, text: text)) {
                                Haptics.success()
                                dismiss()
                            }
                            saving = false
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == line.text)
                }
            }
            .onAppear {
                text = line.text
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: A chat's info

/// A chat's info, as the Mac's (`ChatsInfoSheet`): its face and name, calling and opening it in its app on this phone,
/// what its app says about it, its people and admins, and the chat's own actions.
struct InboxInfoSheet: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    let chat: InboxChatDigest
    let confirm: (InboxConfirm) -> Void
    @ObservedObject private var pictures = ChatPictures.shared

    private var info: InboxChatInfo? { client.inboxInfo[chat.id] }
    private var phone: String? { info?.details.first { $0.key == "phone" }?.value }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: Theme.Spacing.md) {
                        InboxAvatar(name: chat.name, app: chat.app, size: 72, picture: pictures.image(for: chat))
                        Text(verbatim: chat.name).font(Theme.TextStyle.title).foregroundStyle(Theme.paper).multilineTextAlignment(.center)
                        Text(verbatim: [chat.appName, chat.account].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                        HStack(spacing: Theme.Spacing.md) {
                            if let phone, let call = InboxAppLink.call(phone) {
                                tile("phone.fill", String(localized: "Call")) { UIApplication.shared.open(call) }
                            }
                            if let open = InboxAppLink.open(chat, phone: phone) {
                                tile("arrow.up.forward.app", chat.appName) { UIApplication.shared.open(open) }
                            }
                        }
                        .padding(.top, Theme.Spacing.xs)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                if let about = info?.about {
                    Section(chat.group == true ? "Description" : "About") {
                        Text(verbatim: about).font(Theme.TextStyle.body).foregroundStyle(Theme.paper).textSelection(.enabled)
                    }
                }
                if let details = info?.details.filter({ $0.key != "phone" || chat.group != true }), !details.isEmpty {
                    Section {
                        ForEach(details, id: \.key) { detail in
                            LabeledContent {
                                Text(verbatim: Self.value(detail)).textSelection(.enabled)
                            } label: {
                                Text(Self.label(detail.key))
                            }
                            .font(Theme.TextStyle.body)
                        }
                    }
                }
                if let info, info.blocked || info.bot || info.verified || info.adminsOnly {
                    Section {
                        if info.verified { Label("Verified", systemImage: "checkmark.seal") }
                        if info.bot { Label("A bot", systemImage: "cpu") }
                        if info.blocked { Label("Blocked in \(chat.appName)", systemImage: "hand.raised") }
                        if info.adminsOnly { Label("Only admins can send messages", systemImage: "lock") }
                    }
                    .font(Theme.TextStyle.body)
                }
                if let admins = info?.admins, !admins.isEmpty {
                    Section("Admins") {
                        ForEach(Array(admins.enumerated()), id: \.offset) { _, name in person(name) }
                    }
                }
                if let members = info?.members, !members.isEmpty {
                    Section("\(members.count) people") {
                        ForEach(Array(members.enumerated()), id: \.offset) { _, name in person(name) }
                    }
                }
                InboxChatActions(chat: chat, confirm: { item in
                    dismiss()
                    confirm(item)
                })
            }
            .navigationTitle(Text("Chat info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await client.loadInboxInfo(chat.id) }
        }
    }

    private func person(_ name: String) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            ChatInitialsFace(name: name, initials: InboxAvatar.initials(name), size: 30).accessibilityHidden(true)
            Text(verbatim: name).font(Theme.TextStyle.body).foregroundStyle(Theme.paper).lineLimit(1)
        }
    }

    private func tile(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xs) {
                Image(icon: symbol).font(Theme.font(17, .semibold))
                Text(verbatim: title).font(Theme.TextStyle.caption).lineLimit(1)
            }
            .foregroundStyle(Theme.paper)
            .frame(width: 96, height: 58)
            .background(Theme.surface, in: Theme.shape(Theme.Radius.card))
        }
        .buttonStyle(.plain)
    }

    /// What a detail is, in this phone's language.
    static func label(_ key: String) -> LocalizedStringKey {
        switch key {
        case "phone": return "Phone"
        case "username": return "Username"
        case "email": return "Email"
        case "title": return "Job title"
        case "ownName": return "Own name"
        case "business": return "Business"
        case "category": return "Category"
        case "address": return "Address"
        case "website": return "Website"
        case "location": return "Location"
        case "createdBy": return "Created by"
        case "created": return "Created"
        case "memberCount": return "People"
        default: return LocalizedStringKey(key)
        }
    }

    static func value(_ detail: InboxChatInfo.Detail) -> String {
        if detail.key == "created", let seconds = Double(detail.value) {
            return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .omitted)
        }
        return detail.value
    }
}

// MARK: Photos

/// A photo full screen, zoomable, to share or save from the phone's own share sheet.
struct InboxPhotoViewer: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, min(4, $0.magnification)) }
                    .onEnded { _ in withAnimation(Theme.reveal) { scale = 1 } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .navigationTitle(Text(verbatim: title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(Text(verbatim: title), image: Image(uiImage: image)))
                    }
                }
        }
    }
}

/// A photo to enlarge (`sheet(item:)`).
struct InboxPhoto: Identifiable {
    let id: String
    let image: UIImage
    let title: String
}

// MARK: Pictures and files with your words

/// What goes with the next message to a chat: pictures and a file, within what one message may carry
/// (`CompanionFile.fits`).
struct InboxAttachments: Equatable {
    var images: [CompanionImage] = []
    var files: [CompanionFile] = []

    var isEmpty: Bool { images.isEmpty && files.isEmpty }
}

/// The round "+" before the field: pictures from the library or the camera, or a file, as far as the chat's app takes
/// them (`InboxAbility.photo`, `.file`).
struct InboxAttachButton: View {
    @Binding var attachments: InboxAttachments
    let photos: Bool
    let files: Bool
    var tint: Color = Theme.textSecondary
    /// What the notice says when a file is too large: in a chat, to send it from the chat's own app.
    var tooLargeNote: LocalizedStringKey = "A file from the phone can be at most 150 KB. Send larger files from the chat's own app."
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var camera = false
    @State private var tooLarge = false

    var body: some View {
        // The Mac chat composer's "+": the choices as tinted tiles, each opening its picker once the panel is gone.
        ComposerDropdown(title: "Attach") {
            Image(icon: "plus")
                .font(Theme.font(17, .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        } content: {
            DropdownTileGrid {
                if photos {
                    DropdownTile(symbol: "photo.on.rectangle", title: String(localized: "Photo library"), tint: Theme.textStrong) { picking = true }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        DropdownTile(symbol: "camera", title: String(localized: "Camera"), tint: Theme.textStrong) { camera = true }
                    }
                }
                if files {
                    DropdownTile(symbol: "doc.fill", title: String(localized: "File"), tint: Theme.textStrong) { importing = true }
                }
            }
        }
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: max(1, CompanionImage.maxCount - attachments.images.count),
                      matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let loaded = await CompanionImageEncoder.load(items)
                picked = []
                add(images: loaded)
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { image in
                if let image, let encoded = CompanionImageEncoder.encode(image) { add(images: [encoded]) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= CompanionFile.maxBytes else {
                tooLarge = true
                Haptics.warning()
                return
            }
            var next = attachments
            next.files = [CompanionFile(name: url.lastPathComponent, bytes: data)]
            guard CompanionFile.fits(images: next.images, files: next.files) else {
                tooLarge = true
                return
            }
            withAnimation(Theme.reveal) { attachments = next }
        }
        .alert("Too large to send from your phone", isPresented: $tooLarge) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tooLargeNote)
        }
    }

    private func add(images: [CompanionImage]) {
        var next = attachments
        next.images = Array((next.images + images).prefix(CompanionImage.maxCount))
        guard CompanionFile.fits(images: next.images, files: next.files) else {
            tooLarge = true
            return
        }
        if images.isEmpty { Haptics.warning() }
        withAnimation(Theme.reveal) { attachments = next }
    }
}

/// What waits to go with the next message, above the field: the pictures, and the file by name, each to take off.
struct InboxAttachmentTray: View {
    @Binding var attachments: InboxAttachments

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ImageTray(images: $attachments.images)
                ForEach(Array(attachments.files.enumerated()), id: \.offset) { index, file in
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(icon: "doc").foregroundStyle(Theme.textSecondary)
                        Text(verbatim: file.name).font(Theme.TextStyle.detail).foregroundStyle(Theme.paper).lineLimit(1)
                        Spacer(minLength: Theme.Spacing.md)
                        Button {
                            withAnimation(Theme.reveal) { _ = attachments.files.remove(at: index) }
                        } label: {
                            Image(icon: "xmark").font(Theme.font(10, .bold)).foregroundStyle(Theme.textTertiary)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Remove file")
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }
}

/// The phone's camera, for a picture to send.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onPick(info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onPick(nil)
            parent.dismiss()
        }
    }
}

// MARK: The chat's app on this phone

/// Opening a chat's app on the phone itself, and calling: where the Mac starts a call in the app on the Mac, the phone
/// has the app (and a phone) of its own. Only links each app documents; nil when there is none.
enum InboxAppLink {
    static func open(_ chat: InboxChatDigest, phone: String? = nil) -> URL? {
        let digits = phone.map { $0.filter(\.isNumber) }
        switch chat.app {
        case "whatsapp":
            if let digits, !digits.isEmpty { return URL(string: "whatsapp://send?phone=\(digits)") }
            return URL(string: "whatsapp://")
        case "telegram": return URL(string: "tg://")
        case "signal": return URL(string: "sgnl://")
        case "messages":
            if let digits, !digits.isEmpty { return URL(string: "sms:\(digits)") }
            return URL(string: "sms:")
        case "slack": return URL(string: "slack://")
        case "teams": return URL(string: "msteams://")
        case "instagram": return URL(string: "instagram://direct-inbox")
        case "messenger": return URL(string: "fb-messenger://")
        case "discord": return URL(string: "discord://")
        case "linkedin": return URL(string: "linkedin://messaging")
        case "snapchat": return URL(string: "snapchat://")
        case "mail", "gmail", "outlook": return URL(string: "message://")
        default: return nil
        }
    }

    /// A phone call to this number.
    static func call(_ phone: String) -> URL? {
        let dialable = phone.filter { $0.isNumber || $0 == "+" }
        guard dialable.count >= 4 else { return nil }
        return URL(string: "tel:\(dialable)")
    }
}
