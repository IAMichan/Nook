import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Chats tab on the phone does what the Mac's does (`CompanionFeature.chatActions`, `CompanionChats.swift`): every
/// action goes through the same `AppModel` calls as the Mac's Chats tab, and with them through `runInChat`, which checks
/// again that the chat's app takes it. Always after your own tap on the phone; each one is logged as on the Mac, and as
/// coming from the phone.
extension CompanionServer {
    /// An action in a chat (`CompanionOp.inboxAct`): answered with the chat's messages and the list as they are after it.
    func inboxAct(_ request: CompanionRequest, app: AppModel, allKinds: Bool) async -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        guard let action = request.chatAction, action.isComplete else { return .failure(request.id, .badRequest) }
        let route = app.chatRoute(for: entry)
        if let needs = action.needs, !Self.abilities(app.chatAbilities(route)).contains(needs) {
            return .failure(request.id, .notAllowedFromPhone)
        }
        do {
            try await perform(action, in: entry, route: route, app: app)
        } catch {
            return .failure(request.id, .failed, message: error.localizedDescription)
        }
        audit("chat_" + action.kind.rawValue, entry.name)
        var response = inbox(request, app: app, allKinds: allKinds)
        if let current = inboxEntry(entry.id) {
            let page = inboxPage(current, before: nil)
            response.inboxLines = page.lines
            response.inboxTyping = Self.typing(current.id)
            response.inboxChat = current.id
            response.inboxMore = page.more || app.canLoadOlderChat(current)
        }
        return response
    }

    /// The action itself, through the Mac Chats tab's own calls.
    private func perform(_ action: InboxAction, in entry: ChatsEntry, route: ChatRoute?, app: AppModel) async throws {
        let unsupported = NookError(tr(ChatAction.Refusal.unsupported.rawValue))
        /// The message acted on, as the Chats tab has it.
        func bubble() throws -> ChatBubble {
            guard let id = action.message, let bubble = inboxBubbles(entry).first(where: { $0.id == id }), !bubble.local else {
                throw NookError(tr("chat.forward.notHere"))
            }
            return bubble
        }
        switch action.kind {
        case .react:
            guard let route, let emoji = action.emoji else { throw unsupported }
            let target = try bubble()
            guard !target.deleted else { throw unsupported }
            try await app.reactInChat(emoji, to: target, route: route, thread: entry.id, name: entry.name)
        case .edit:
            guard let route, let text = CompanionPolicy.cleanMessage(action.text ?? ""), ChatDraft.instruction(in: text) == nil else {
                throw unsupported
            }
            let target = try bubble()
            guard !target.deleted, target.poll == nil else { throw unsupported }
            try await app.editInChat(target, text: text, route: route, name: entry.name)
        case .delete:
            guard let route else { throw unsupported }
            let target = try bubble()
            guard !target.deleted else { throw unsupported }
            try await app.deleteInChat(target, route: route, name: entry.name)
        case .deleteForMe:
            app.deleteInChatForMe(try bubble(), route: route, chat: entry.id, name: entry.name)
        case .vote:
            guard let route else { throw unsupported }
            let target = try bubble()
            guard let poll = target.poll else { throw unsupported }
            let valid = Set(poll.options.map(\.text))
            let choice = (action.choices ?? []).filter(valid.contains)
            guard poll.multiple || choice.count <= 1 else { throw unsupported }
            try await app.voteInChat(choice, on: target, route: route, name: entry.name)
        case .forward:
            try await forward(try bubble(), to: action.targets ?? [], app: app)
        case .pin:
            ChatPins.shared.setPinned(action.value == true, chat: entry.id)
        case .pinInApp:
            guard let route else { throw unsupported }
            try await app.setChatPinned(action.value == true, route: route, name: entry.name)
        case .muteInApp:
            guard let route else { throw unsupported }
            try await app.setChatMuted(action.value == true, route: route, name: entry.name)
        case .archive:
            guard let route else { throw unsupported }
            try await app.archiveChat(route: route, thread: app.chatThread(entry), name: entry.name)
        case .deleteChat:
            guard let route else { throw unsupported }
            try await app.deleteChatInApp(route: route, thread: app.chatThread(entry), name: entry.name)
        case .remove:
            ChatCaptureService.shared.remove(entry.id)
        case .markReadInNook:
            app.markChatReadInNook(entry)
        case .markReadInApp:
            // Only where Nook can tell the app: the phone never opens an app on the Mac.
            guard app.chatReadHandoff(entry) == .tells else { throw unsupported }
            app.markChatReadInApp(entry)
        case .markUnread:
            app.markChatUnread(entry)
        }
    }

    /// A message forwarded to other chats, as the Mac's forward picker sends it: its file when Nook has it on this Mac,
    /// with its text, through each chat's own route. A chat that cannot take it is left out; any failure says which.
    private func forward(_ bubble: ChatBubble, to targets: [String], app: AppModel) async throws {
        guard !bubble.deleted, bubble.poll == nil else { throw NookError(tr("chat.forward.notHere")) }
        let (file, kind): (URL?, ChatMedia.Kind?) = {
            switch bubble.media {
            case .photo(let url): return (url, .photo)
            case .video(let url): return (url, .video)
            case .gif(let url): return (url, .gif)
            case .sticker(let url): return (url, .sticker)
            case .audio(let url, _): return (url, .audio)
            case .file, .photoComing: return (bubble.attachment == nil ? nil : bubble.file, nil)
            }
        }()
        guard bubble.attachment == nil || file != nil, let message = ChatForward(text: bubble.text, file: file, kind: kind) else {
            throw NookError(tr("chat.forward.notHere"))
        }
        var failed: [String] = []
        var lastError: Error?
        for id in Set(targets).prefix(InboxAction.maxTargets) {
            guard let target = inboxEntry(id) else { continue }
            do {
                try await app.forwardChatMessage(message, to: target)
            } catch {
                failed.append(target.name)
                lastError = error
            }
        }
        if let lastError {
            throw NookError(tr("chat.forward.failed", failed.joined(separator: ", ")) + " " + lastError.localizedDescription)
        }
    }

    /// Older messages of a chat (`CompanionOp.inboxOlder`, `text` the oldest one the phone has): from what Nook has, else
    /// read back from the chat's app first, as scrolling up in the Mac's Chats tab does.
    func inboxOlder(_ request: CompanionRequest, app: AppModel) async -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        guard let before = request.text, !before.isEmpty else { return .failure(request.id, .badRequest) }
        var page = inboxPage(entry, before: before)
        if page.lines.isEmpty, app.canLoadOlderChat(entry), await app.loadOlderChat(entry), let current = inboxEntry(entry.id) {
            page = inboxPage(current, before: before)
        }
        var response = CompanionResponse(id: request.id, ok: true, inboxLines: page.lines)
        response.inboxChat = entry.id
        response.inboxBefore = before
        response.inboxMore = page.more || (inboxEntry(entry.id).map(app.canLoadOlderChat) ?? false)
        return response
    }

    /// The photos of messages (`CompanionOp.inboxMedia`): of a chat the phone can list, made off the main thread.
    func inboxMedia(_ request: CompanionRequest) async -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        let wanted = Set((request.items ?? []).prefix(InboxMedia.batch))
        guard !wanted.isEmpty else { return .failure(request.id, .badRequest) }
        let files = inboxBubbles(entry, ids: wanted).compactMap { bubble -> (String, URL, String, Bool)? in
            let media = CompanionChatMedia.describe(bubble)
            guard let url = media.url, let version = media.version else { return nil }
            return (bubble.id, url, version, media.kind == "video")
        }
        var made: [InboxMedia] = []
        for (line, url, version, video) in files {
            guard let data = await CompanionChatMedia.jpeg(url, video: video) else { continue }
            made.append(InboxMedia(line: line, version: version, jpeg: data.base64EncodedString()))
        }
        var response = CompanionResponse(id: request.id, ok: true)
        response.inboxMedia = made
        return response
    }

    /// A chat's info (`CompanionOp.inboxInfo`), as the Mac's chat info shows it.
    func inboxInfo(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        guard let entry = inboxEntry(request.item) else { return .failure(request.id, .unknownItem) }
        let profile = entry.profile ?? ChatProfile()
        let clip = { (text: String) in CompanionPolicy.clip(text, limit: 300) }
        var details: [InboxChatInfo.Detail] = []
        func add(_ key: String, _ value: String?) {
            if let value = ChatProfile.text(value) { details.append(.init(key: key, value: clip(value))) }
        }
        add("phone", app.chatPhone(entry))
        add("username", profile.username)
        add("email", profile.email)
        add("title", profile.title)
        add("ownName", profile.ownName)
        add("business", profile.business)
        add("category", profile.category)
        add("address", profile.address)
        add("website", profile.website)
        add("location", profile.location)
        add("createdBy", profile.createdBy)
        if let created = profile.created { details.append(.init(key: "created", value: String(Int(created.timeIntervalSince1970)))) }
        if let count = profile.memberCount { details.append(.init(key: "memberCount", value: String(count))) }
        let info = InboxChatInfo(chat: entry.id, about: ChatProfile.text(profile.about).map { CompanionPolicy.clip($0, limit: 2_000) },
                                 members: (entry.members ?? []).prefix(InboxChatInfo.maxMembers).map { CompanionPolicy.clip($0, limit: 120) },
                                 admins: (profile.admins ?? []).prefix(InboxChatInfo.maxMembers).map { CompanionPolicy.clip($0, limit: 120) },
                                 adminsOnly: profile.adminsOnly == true, details: details,
                                 blocked: profile.blocked == true, bot: profile.bot == true, verified: profile.verified == true)
        var response = CompanionResponse(id: request.id, ok: true)
        response.inboxInfo = info
        return response
    }

    /// The chats whose name, people or messages hold the words (`CompanionOp.inboxSearch`), as the Mac's search finds
    /// them: a chat found by a message shows that message as its line.
    func inboxSearch(_ request: CompanionRequest, app: AppModel) -> CompanionResponse {
        let needle = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle.count <= 200 else { return .failure(request.id, .badRequest) }
        let capture = ChatCaptureService.shared
        _ = capture.loadedInbox
        let found = ChatsEntry.all(capture: capture).lazy.compactMap { $0.found(needle, capture: capture) }.prefix(Self.inboxLimit)
        var response = CompanionResponse(id: request.id, ok: true)
        response.inboxFound = found.map { digest($0, app: app) }
        return response
    }
}

/// The photos in chat messages as the phone gets them (`InboxMedia`): what a bubble's file is, which version of its
/// photo the phone keeps, and the photo itself as a JPEG small enough for one answer.
enum CompanionChatMedia {
    struct Described {
        var kind: String?
        var url: URL?
        var version: String?
        var seconds: Double?
    }

    /// What a bubble's file is for the phone, and where its picture comes from (a photo, a sticker, a GIF's file, a
    /// video's first frame). A file Nook does not have on this Mac yet has a kind but no picture.
    @MainActor
    static func describe(_ bubble: ChatBubble) -> Described {
        switch bubble.media {
        case .photo(let url): return Described(kind: "photo", url: url, version: CompanionAvatars.version(url.path))
        case .photoComing: return Described(kind: "photo")
        case .video(let url): return Described(kind: "video", url: url, version: CompanionAvatars.version(url.path))
        case .gif(let url): return Described(kind: "gif", url: url, version: CompanionAvatars.version(url.path))
        case .sticker(let url): return Described(kind: "sticker", url: url, version: CompanionAvatars.version(url.path))
        case .audio(_, let seconds):
            return Described(kind: "audio", seconds: seconds)
        case .file: return Described(kind: bubble.attachment == nil ? nil : "file")
        }
    }

    /// The picture as a JPEG of at most `InboxMedia.side` pixels on its longest side and `InboxMedia.maxBytes`, made off
    /// the main thread; a video's first frame. Nil when it cannot be read.
    static func jpeg(_ url: URL, video: Bool) async -> Data? {
        if video {
            guard let frame = await ChatFileThumbnails.shared.image(url, kind: .video),
                  let image = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return await Task.detached(priority: .utility) { encode(image) }.value
        }
        return await Task.detached(priority: .utility) { () -> Data? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: InboxMedia.side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return encode(image)
        }.value
    }

    /// The image as a JPEG within `InboxMedia.maxBytes`: smaller and more compressed until it fits.
    static func encode(_ image: CGImage) -> Data? {
        var current = image
        for quality in [0.7, 0.55, 0.4, 0.3] {
            if let data = jpegData(current, quality: quality), data.count <= InboxMedia.maxBytes { return data }
            if quality == 0.4, let smaller = scaled(current, by: 0.66) { current = smaller }
        }
        return nil
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
