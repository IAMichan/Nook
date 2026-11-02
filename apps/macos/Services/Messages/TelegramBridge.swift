import Foundation
import Combine

/// Telegram with its history, through TDLib: Telegram's own client library, built once with scripts/build-tdlib.sh and
/// shipped inside Nook.app signed like Nook itself, so the hardened runtime and library validation stay on. You log in
/// as on a new phone or computer (your number, the code Telegram sends you, your password when you set one); the
/// session is kept in Nook's support folder and Telegram lists it under Settings › Devices. Nook asks for your chats
/// and their messages, and sends only what you send yourself from the Chats tab (text, files, polls, places, contacts).
/// The app id and hash are your own, from my.telegram.org. A build with Nook's own chat helper (`ChatHelper`) links
/// Telegram through it instead, and this stays off.
@MainActor
final class TelegramBridge: ObservableObject, ChatHistoryBridge, ChatSearchBridge {
    let app = "telegram"
    let interval: TimeInterval = 3

    enum State: Equatable {
        /// TDLib is not in this build: run scripts/build-tdlib.sh and build Nook again.
        case noLibrary
        /// The app id and hash from my.telegram.org are not set yet.
        case noKeys
        case stopped
        case starting
        case login(TelegramData.Authorization)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    /// The last login step that went wrong (a wrong code), shown under the field.
    @Published private(set) var loginError: String?
    /// Who is logged in.
    @Published private(set) var account: String?

    static let apiIDAccount = "chats.telegram.apiID"
    static let apiHashAccount = "chats.telegram.apiHash"
    /// Chats and messages per chat read after logging in; new messages come in as Telegram sends them.
    private static let chatCount = 30
    private static let history = 30

    private var client: TDLibClient?
    private var chats: [Int64: TelegramData.Chat] = [:]
    private var users: [Int64: String] = [:]
    private var messages: [Int64: [InboxMessage]] = [:]
    /// Messages Telegram deleted for good since the last `read()`, by chat: their ids in Nook, so the chat drops them.
    private var deleted: [Int64: [String]] = [:]
    /// Each chat's notification settings as TDLib last sent them, so muting changes only that.
    private var notificationSettings: [Int64: [String: Any]] = [:]
    private var actionCount = 0
    /// Chats whose messages or unread count changed since the last `read()`.
    private var changed: Set<Int64> = []
    /// The chats Nook shows: the newest of the main list, plus every chat a new message arrives in.
    private var shown: Set<Int64> = []
    /// Files asked of TDLib to show in a chat (a photo, a sticker, a voice message…), by their id: which message has it.
    private var downloads: [Int64: (chat: Int64, message: String)] = [:]
    /// Chat pictures asked of TDLib, by their file id: whose picture it is.
    private var pictures: [Int64: Int64] = [:]
    /// Your own user id, to leave you out of a group's people.
    private var meID: Int64?
    /// Each group's people by user id, asked once per chat.
    private var members: [Int64: [Int64]] = [:]
    private var membersAsked: Set<Int64> = []
    /// Your messages in groups whose viewers were asked, and when: asked again once the chat says more of them was read.
    private var viewersAsked: [String: Int64] = [:]
    /// Of how many of your newest messages in a group Telegram is asked who read them (it keeps that for a week, in
    /// groups of up to 100 people).
    private static let viewed = 5
    /// Messages Nook asked TDLib to send, by the `@extra` of the request: what to ask again in the older shape when a
    /// TDLib from before that shape refuses it, and the first refusal, which is the one that explains.
    private var sending: [String: (legacy: [String: Any]?, error: String?)] = [:]
    private var sendCount = 0
    /// Scrolling back: TDLib's answer awaited per chat ("older:<id>").
    private var olderWaiting: [Int64: CheckedContinuation<[[String: Any]], Never>] = [:]
    /// Search everything: TDLib's answer awaited per search ("search:<n>").
    private var searchWaiting: [String: CheckedContinuation<[[String: Any]], Never>] = [:]
    private var searchCount = 0

    var isReady: Bool { state == .login(.ready) }
    var isWorking: Bool { isReady }

    /// Your own app id and hash, else the ones this build of Nook comes with (Info.plist), so you only log in.
    static var keys: (id: Int, hash: String)? {
        if let id = CloudHelp.secret(apiIDAccount).flatMap(Int.init), let hash = CloudHelp.secret(apiHashAccount), !hash.isEmpty {
            return (id, hash)
        }
        guard let id = (Bundle.main.object(forInfoDictionaryKey: "NookTelegramAPIID") as? String).flatMap(Int.init),
              let hash = Bundle.main.object(forInfoDictionaryKey: "NookTelegramAPIHash") as? String, !hash.isEmpty else { return nil }
        return (id, hash)
    }

    /// TDLib is in this build and Nook's chat helper, which links Telegram itself, is not.
    static var libraryURL: URL? {
        guard !ChatHelper.isBuilt, let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libtdjson.dylib"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Where TDLib keeps the session and its cache: Nook's support folder, readable by you alone.
    private static var directory: URL {
        let url = NookPaths.supportDirectory.appendingPathComponent("telegram", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Whether a session was kept from an earlier login: then starting needs no login again.
    var hasSession: Bool {
        FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("td.binlog").path)
    }

    /// Starts TDLib when it can: it is built in, the keys are set. Logging in continues where it was.
    func start() {
        guard client == nil else { return }
        guard let library = Self.libraryURL else { state = .noLibrary; return }
        guard Self.keys != nil else { state = .noKeys; return }
        do {
            state = .starting
            loginError = nil
            client = try TDLibClient(library: library) { [weak self] object in
                Task { @MainActor in self?.handle(object) }
            }
            // The first request wakes TDLib up; it answers with where the login stands.
            send(["@type": "getOption", "name": "version"])
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Starts again with a session that was kept, so Telegram works after a relaunch without asking anything.
    func resume() {
        if hasSession { start() } else if state == .stopped || state == .noKeys || state == .noLibrary {
            state = Self.libraryURL == nil ? .noLibrary : (Self.keys == nil ? .noKeys : .stopped)
        }
    }

    func stop() {
        client?.close()
        client = nil
        // A scroll back still waiting gets no answer any more.
        for waiting in olderWaiting.values { waiting.resume(returning: []) }
        olderWaiting = [:]
        for waiting in searchWaiting.values { waiting.resume(returning: []) }
        searchWaiting = [:]
        if case .login = state { state = .stopped }
        if state == .starting { state = .stopped }
    }

    // MARK: Logging in

    func sendPhone(_ phone: String) {
        loginError = nil
        send(["@type": "setAuthenticationPhoneNumber", "phone_number": phone.filter { $0.isNumber || $0 == "+" }, "@extra": "login"])
    }

    func sendCode(_ code: String) {
        loginError = nil
        send(["@type": "checkAuthenticationCode", "code": code.filter(\.isNumber), "@extra": "login"])
    }

    func sendPassword(_ password: String) {
        loginError = nil
        send(["@type": "checkAuthenticationPassword", "password": password, "@extra": "login"])
    }

    /// Ends the session at Telegram and forgets it here.
    func logOut() {
        send(["@type": "logOut"])
        account = nil
        chats = [:]
        messages = [:]
        deleted = [:]
        notificationSettings = [:]
        shown = []
        changed = []
        meID = nil
        members = [:]
        membersAsked = []
        viewersAsked = [:]
    }

    // MARK: ChatBridge

    func read() async throws -> [BridgedChat] {
        guard isReady else { return [] }
        let ids = changed.intersection(shown)
        let gone = deleted
        changed = []
        deleted = [:]
        return ids.compactMap { id in
            guard let chat = chats[id], !chat.title.isEmpty else { return nil }
            let people = (members[id] ?? []).filter { $0 != meID }.compactMap { users[$0] }
            return BridgedChat(app: app, name: chat.title, messages: messages[id] ?? [], unread: chat.unread, avatar: chat.avatar,
                               members: people.isEmpty ? nil : people, deleted: gone[id] ?? [])
        }
    }

    // MARK: Scrolling back

    /// The chat Nook shows as `name`.
    private func chatID(_ name: String) -> Int64? {
        let key = ChatInbox.key(app: app, chat: name)
        return chats.first { !$0.value.title.isEmpty && ChatInbox.key(app: app, chat: $0.value.title) == key }?.key
    }

    func canLoadOlder(name: String) -> Bool { isReady && chatID(name) != nil }

    /// The batch before the oldest message Nook shows, from Telegram's servers: as far back as the chat goes.
    func older(name: String, before: Date, oldestID: String?) async throws -> (chat: BridgedChat?, hasMore: Bool) {
        guard isReady, client != nil, let id = chatID(name), let chat = chats[id], olderWaiting[id] == nil else { return (nil, false) }
        // From the oldest message Nook shows; one a notification brought has no Telegram id, so from the oldest read here.
        let shown = oldestID.flatMap { TelegramData.ids($0) }.flatMap { $0.chat == id ? $0.message : nil }
        guard var from = shown ?? (messages[id] ?? []).compactMap({ TelegramData.ids($0.id)?.message }).min() else { return (nil, false) }
        // A batch of only what a chat does not show (someone joined, a pinned message) goes on to the one before it.
        for _ in 0..<5 {
            let list = await withCheckedContinuation { continuation in
                olderWaiting[id] = continuation
                send(["@type": "getChatHistory", "chat_id": id, "from_message_id": from, "offset": 0,
                      "limit": ChatHistory.step, "only_local": false, "@extra": "older:\(id)"])
            }
            // TDLib answers with nothing once the chat's start is reached.
            guard let oldest = list.compactMap({ TelegramData.int64($0["id"]) }).min(), oldest < from else { return (nil, false) }
            let found = list.compactMap { TelegramData.message($0, chat: chat, users: users) }
                .filter { (TelegramData.ids($0.id)?.message ?? .max) < from }
            from = oldest
            guard !found.isEmpty else { continue }
            let people = (members[id] ?? []).filter { $0 != meID }.compactMap { users[$0] }
            return (BridgedChat(app: app, name: name, messages: found.sorted { $0.date < $1.date }, unread: nil,
                                members: people.isEmpty ? nil : people), true)
        }
        return (nil, true)
    }

    // MARK: Search everything

    var searchesHistory: Bool { isReady && client != nil }

    /// Telegram's own search through every chat in the main list (`searchMessages`), on its servers: as far back as each
    /// chat goes. Only the chats Nook knows by name are kept, so a hit opens a chat it shows.
    func searchHistory(_ words: [String], limit: Int) async throws -> [BridgedChat] {
        guard isReady, client != nil, !words.isEmpty else { return [] }
        var found: [(chat: BridgedChat, messages: [InboxMessage])] = []
        for word in words {
            searchCount += 1
            let extra = "search:\(searchCount)"
            let list = await withCheckedContinuation { continuation in
                searchWaiting[extra] = continuation
                send(["@type": "searchMessages", "chat_list": ["@type": "chatListMain"], "query": word, "offset": "",
                      "limit": min(limit, 100), "min_date": 0, "max_date": 0, "@extra": extra])
            }
            for object in list {
                guard let id = TelegramData.int64(object["chat_id"]), let chat = chats[id], !chat.title.isEmpty,
                      let message = TelegramData.message(object, chat: chat, users: users),
                      ChatHistorySearch.matches(message, [word]) else { continue }
                found.append((BridgedChat(app: app, name: chat.title, messages: [], unread: nil, avatar: chat.avatar), [message]))
            }
        }
        return ChatHistorySearch.chats(found)
    }

    /// TDLib's answer to a search (nothing, when it refused).
    private func answerSearch(_ extra: String, _ list: [[String: Any]]) {
        searchWaiting.removeValue(forKey: extra)?.resume(returning: list)
    }

    /// TDLib's answer to a scroll back (nothing, when it refused).
    private func answerOlder(_ extra: String, _ list: [[String: Any]]) {
        guard let id = Int64(extra.dropFirst("older:".count)), let waiting = olderWaiting.removeValue(forKey: id) else { return }
        waiting.resume(returning: list)
    }

    // MARK: TDLib

    private func send(_ request: [String: Any]) {
        guard let client, let json = TelegramData.request(request) else { return }
        client.send(json)
    }

    private func handle(_ object: [String: Any]) {
        switch TelegramData.type(object) {
        case "updateAuthorizationState":
            authorization(TelegramData.authorization(object))
        case "updateNewChat":
            if let raw = object["chat"] as? [String: Any], let chat = TelegramData.chat(raw) {
                chats[chat.id] = chat
                notificationSettings[chat.id] = raw["notification_settings"] as? [String: Any]
                fetchPicture(of: chat.id)
            }
        case "chat":
            // A chat asked again after a pin or mute Telegram refused: it shows as Telegram has it.
            if object["@extra"] as? String == "refresh", let chat = TelegramData.chat(object) {
                chats[chat.id]?.isPinned = chat.isPinned
                chats[chat.id]?.isMuted = chat.isMuted
                notificationSettings[chat.id] = object["notification_settings"] as? [String: Any]
                changed.insert(chat.id)
            }
        case "updateChatPosition":
            // Pinned or unpinned (on any device), or moved in the main list.
            if let position = TelegramData.mainPosition(object) {
                chats[position.chat]?.order = position.order
                chats[position.chat]?.isPinned = position.pinned
            }
        case "updateChatNotificationSettings":
            if let id = TelegramData.int64(object["chat_id"]), let settings = object["notification_settings"] as? [String: Any] {
                chats[id]?.isMuted = TelegramData.isMuted(settings)
                notificationSettings[id] = settings
            }
        case "updateDeleteMessages":
            // Deleted for everyone (by you, from here or elsewhere, or by someone else): the chat drops them.
            if let gone = TelegramData.deletedMessages(object) {
                let ids = Set(gone.messages.map { "telegram-\(gone.chat)-\($0)" })
                messages[gone.chat]?.removeAll { ids.contains($0.id) }
                deleted[gone.chat, default: []].append(contentsOf: ids.sorted())
                changed.insert(gone.chat)
            }
        case "updateChatPhoto":
            if let id = TelegramData.int64(object["chat_id"]) {
                let picture = TelegramData.photo(object["photo"])
                chats[id]?.photo = picture?.id
                chats[id]?.avatar = picture?.path
                changed.insert(id)
                fetchPicture(of: id)
            }
        case "updateChatTitle":
            if let id = TelegramData.int64(object["chat_id"]), let title = object["title"] as? String {
                chats[id]?.title = title
                changed.insert(id)
            }
        case "updateChatReadOutbox":
            // Someone read your messages up to this one: they get two ticks, and in a group Telegram says who.
            if let id = TelegramData.int64(object["chat_id"]), let upTo = TelegramData.int64(object["last_read_outbox_message_id"]) {
                chats[id]?.readOutbox = upTo
                markRead(upTo: upTo, in: id)
                askViewers(in: id)
            }
        case "basicGroupFullInfo", "chatMembers":
            if let extra = object["@extra"] as? String, extra.hasPrefix("members:"), let id = Int64(extra.dropFirst("members:".count)) {
                members[id] = TelegramData.members(object)
                changed.insert(id)
            }
        case "messageViewers", "users":
            if let extra = object["@extra"] as? String, extra.hasPrefix("viewers:") { viewed(TelegramData.viewers(object), extra: extra) }
        case "messageReadDateRead":
            if let extra = object["@extra"] as? String, extra.hasPrefix("readdate:"), let seconds = TelegramData.int64(object["read_date"]),
               seconds > 0 {
                viewed([(user: 0, date: Date(timeIntervalSince1970: Double(seconds)))], extra: "viewers:" + extra.dropFirst("readdate:".count))
            }
        case "updateChatAction":
            // Telegram repeats an action every few seconds while it lasts, and lets it go after six without a word.
            if let action = TelegramData.chatAction(object), action.user != meID, let chat = chats[action.chat], !chat.title.isEmpty {
                let key = ChatInbox.key(app: app, chat: chat.title)
                if let kind = action.kind {
                    ChatTypingCenter.shared.typing(chat: key, person: String(action.user),
                                                   name: chat.isGroup ? users[action.user] ?? "" : "", kind: kind, seconds: 6)
                } else {
                    ChatTypingCenter.shared.stopped(chat: key, person: String(action.user))
                }
            }
        case "updateChatReadInbox":
            if let id = TelegramData.int64(object["chat_id"]) {
                chats[id]?.unread = Int(TelegramData.int64(object["unread_count"]) ?? 0)
                changed.insert(id)
            }
        case "updateUser":
            if let user = object["user"] as? [String: Any], let id = TelegramData.int64(user["id"]),
               let name = TelegramData.userName(user) {
                users[id] = name
            }
        case "updateMessageContent":
            // A poll's votes moved (or a message was edited): the chat shows the new content.
            if let chat = TelegramData.int64(object["chat_id"]), let id = TelegramData.int64(object["message_id"]),
               let content = object["new_content"] as? [String: Any],
               let index = messages[chat]?.firstIndex(where: { $0.id == "telegram-\(chat)-\(id)" }) {
                if let poll = TelegramData.poll(content) {
                    messages[chat]?[index].poll = poll
                } else if let text = TelegramData.text(content), !text.isEmpty, TelegramData.file(content) == nil {
                    messages[chat]?[index].text = text
                }
                changed.insert(chat)
            }
        case "updateMessageInteractionInfo":
            // Someone put an emoji on a message, or took theirs back: the chat shows it.
            if let chat = TelegramData.int64(object["chat_id"]), let id = TelegramData.int64(object["message_id"]),
               let index = messages[chat]?.firstIndex(where: { $0.id == "telegram-\(chat)-\(id)" }) {
                let reactions = TelegramData.reactions(object["interaction_info"], users: users, me: meID)
                if messages[chat]?[index].reactions != reactions {
                    messages[chat]?[index].reactions = reactions
                    changed.insert(chat)
                }
            }
        case "updateNewMessage":
            // A message you sent from Nook shows once Telegram has it (`updateMessageSendSucceeded`), under its own id.
            if let message = object["message"] as? [String: Any], let id = TelegramData.int64(message["chat_id"]),
               !TelegramData.isPending(message) {
                add([message], to: id)
                shown.insert(id)
                // Their message is here: they stopped typing it.
                if let user = TelegramData.int64((message["sender_id"] as? [String: Any])?["user_id"]),
                   let title = chats[id]?.title, !title.isEmpty {
                    ChatTypingCenter.shared.stopped(chat: ChatInbox.key(app: app, chat: title), person: String(user))
                }
            }
        case "updateMessageSendSucceeded":
            if let message = object["message"] as? [String: Any], let id = TelegramData.int64(message["chat_id"]) {
                add([message], to: id)
                shown.insert(id)
            }
        case "message":
            // TDLib took a message Nook sent: nothing to ask again.
            if let extra = object["@extra"] as? String, extra.hasPrefix("send:") {
                sending[extra.hasSuffix(":legacy") ? String(extra.dropLast(":legacy".count)) : extra] = nil
            }
        case "updateMessageSendFailed":
            let reason = ((object["error"] as? [String: Any])?["message"] as? String) ?? "error"
            ToastCenter.shared.error(tr("chat.compose.notSent"), detail: Self.explain(reason))
        case "chats":
            // The newest chats of the main list: read each one's history.
            let ids = (object["chat_ids"] as? [Any] ?? []).compactMap { TelegramData.int64($0) }.prefix(Self.chatCount)
            for id in ids {
                shown.insert(id)
                send(["@type": "getChatHistory", "chat_id": id, "from_message_id": 0, "offset": 0,
                      "limit": Self.history, "only_local": false, "@extra": "history:\(id)"])
            }
        case "foundMessages":
            // Search everything's search through every chat.
            if let extra = object["@extra"] as? String, extra.hasPrefix("search:") {
                answerSearch(extra, object["messages"] as? [[String: Any]] ?? [])
            }
        case "messages":
            // A chat's history: "history:<id>" the first ask, "history2:<id>" the one before it.
            guard let extra = object["@extra"] as? String else { return }
            if extra.hasPrefix("older:") {
                answerOlder(extra, object["messages"] as? [[String: Any]] ?? [])
                return
            }
            // A TDLib from before `foundMessages` answers a search with plain messages.
            if extra.hasPrefix("search:") {
                answerSearch(extra, object["messages"] as? [[String: Any]] ?? [])
                return
            }
            let first = extra.hasPrefix("history:")
            guard first || extra.hasPrefix("history2:"),
                  let id = extra.split(separator: ":").last.flatMap({ Int64($0) }) else { return }
            let list = object["messages"] as? [[String: Any]] ?? []
            add(list, to: id)
            if first {
                askMembers(of: id)
                askViewers(in: id)
            }
            // TDLib often answers the first ask with only the newest message: ask once more for the ones before it.
            if first, list.count < Self.history, let oldest = list.compactMap({ TelegramData.int64($0["id"]) }).min() {
                send(["@type": "getChatHistory", "chat_id": id, "from_message_id": oldest, "offset": 0,
                      "limit": Self.history, "only_local": false, "@extra": "history2:\(id)"])
            }
        case "file", "updateFile":
            // A file Nook asked for is on this Mac now: its message shows it.
            let file = TelegramData.type(object) == "file" ? object : (object["file"] as? [String: Any] ?? [:])
            if let id = TelegramData.int64(file["id"]), let path = TelegramData.downloaded(file) { downloaded(id, path: path) }
        case "user":
            if object["@extra"] as? String == "me" {
                account = TelegramData.userName(object)
                meID = TelegramData.int64(object["id"])
            }
        case "error":
            let message = (object["message"] as? String) ?? "error"
            if let extra = object["@extra"] as? String, extra.hasPrefix("older:") {
                answerOlder(extra, [])
            } else if let extra = object["@extra"] as? String, extra.hasPrefix("search:") {
                answerSearch(extra, [])
            } else if let extra = object["@extra"] as? String, extra.hasPrefix("send:") {
                refused(extra, message)
            } else if let extra = object["@extra"] as? String, extra.hasPrefix("action:") {
                // A pin, mute, archive, edit, delete, emoji, vote or read mark Telegram refused: the chat is asked again,
                // so it shows as it is.
                ToastCenter.shared.error(tr("chat.action.failed"), detail: Self.explain(message))
                if let chat = extra.split(separator: ":").last.flatMap({ Int64($0) }) {
                    send(["@type": "getChat", "chat_id": chat, "@extra": "refresh"])
                }
            } else if object["@extra"] as? String == "login" {
                loginError = Self.explain(message)
            } else if case .login(let step) = state, step != .ready {
                loginError = Self.explain(message)
            }
        default:
            break
        }
    }

    private func authorization(_ step: TelegramData.Authorization) {
        switch step {
        case .parameters:
            guard let keys = Self.keys else { state = .noKeys; stop(); return }
            send(["@type": "setTdlibParameters", "use_test_dc": false,
                  "database_directory": Self.directory.path, "files_directory": Self.directory.appendingPathComponent("files").path,
                  "database_encryption_key": "", "use_file_database": false, "use_chat_info_database": true,
                  "use_message_database": true, "use_secret_chats": false, "api_id": keys.id, "api_hash": keys.hash,
                  "system_language_code": I18n.shared.currentLanguage.rawValue, "device_model": "Mac",
                  "system_version": ProcessInfo.processInfo.operatingSystemVersionString, "application_version": "Nook"])
        case .encryptionKey:
            send(["@type": "checkDatabaseEncryptionKey", "encryption_key": ""])
        case .ready:
            state = .login(.ready)
            loginError = nil
            send(["@type": "getMe", "@extra": "me"])
            send(["@type": "loadChats", "chat_list": ["@type": "chatListMain"], "limit": Self.chatCount])
            send(["@type": "getChats", "chat_list": ["@type": "chatListMain"], "limit": Self.chatCount])
        case .closed:
            client?.close()
            client = nil
            state = .stopped
        default:
            state = .login(step)
        }
    }

    private func add(_ list: [[String: Any]], to id: Int64) {
        guard let chat = chats[id] else { return }
        var known = messages[id] ?? []
        var ids = Set(known.map(\.id))
        for object in list {
            guard let message = TelegramData.message(object, chat: chat, users: users), ids.insert(message.id).inserted else { continue }
            known.append(message)
            // Its file, when it is not on this Mac yet and not too large to fetch for a chat.
            if let file = TelegramData.file(object["content"] as? [String: Any] ?? [:]), file.media.path == nil,
               file.size <= ChatMedia.maxBytes, downloads[file.id] == nil {
                downloads[file.id] = (id, message.id)
                send(["@type": "downloadFile", "file_id": file.id, "priority": 1, "offset": 0, "limit": 0, "synchronous": true])
            }
        }
        known.sort { $0.date < $1.date }
        if known.count > ChatInbox.keep { known.removeFirst(known.count - ChatInbox.keep) }
        messages[id] = known
        changed.insert(id)
    }

    /// Your messages up to `upTo` were read: two ticks.
    private func markRead(upTo: Int64, in chat: Int64) {
        guard var list = messages[chat] else { return }
        var touched = false
        for index in list.indices where list[index].isMine && (list[index].receipt ?? .sent) < .read {
            guard let ids = TelegramData.ids(list[index].id), ids.message <= upTo else { continue }
            list[index].receipt = (list[index].receipt ?? .sent).advanced(to: .read)
            touched = true
        }
        guard touched else { return }
        messages[chat] = list
        changed.insert(chat)
    }

    /// Who is in a group, asked once: a basic group's full info, or a supergroup's first 200 members.
    private func askMembers(of chat: Int64) {
        guard let group = chats[chat], group.isGroup, membersAsked.insert(chat).inserted else { return }
        if let basic = group.basicGroup {
            send(["@type": "getBasicGroupFullInfo", "basic_group_id": basic, "@extra": "members:\(chat)"])
        } else if let supergroup = group.supergroup {
            send(["@type": "getSupergroupMembers", "supergroup_id": supergroup, "offset": 0, "limit": 200,
                  "@extra": "members:\(chat)"])
        }
    }

    /// Who read your newest messages in a group, or when the other person read them in a private chat: asked of
    /// Telegram for those it says were read since the last ask. Telegram answers only for the last week (a group of up
    /// to 100 people), or when neither of you hides when you read (`getMessageReadDate`); elsewhere the message keeps its
    /// ticks.
    private func askViewers(in chat: Int64) {
        guard let group = chats[chat], group.readOutbox > 0 else { return }
        let week = Date().addingTimeInterval(-7 * 86_400)
        for message in (messages[chat] ?? []).filter({ $0.isMine && $0.date > week }).suffix(Self.viewed) {
            guard let ids = TelegramData.ids(message.id), ids.message <= group.readOutbox,
                  viewersAsked[message.id] != group.readOutbox else { continue }
            viewersAsked[message.id] = group.readOutbox
            if group.isGroup {
                send(["@type": "getMessageViewers", "chat_id": chat, "message_id": ids.message, "@extra": "viewers:\(message.id)"])
            } else {
                send(["@type": "getMessageReadDate", "chat_id": chat, "message_id": ids.message, "@extra": "readdate:\(message.id)"])
            }
        }
        if viewersAsked.count > 500 { viewersAsked.removeAll() }
    }

    /// Telegram's answer to who read one of your messages ("viewers:<message id>"): the message lists them.
    private func viewed(_ viewers: [(user: Int64, date: Date?)], extra: String) {
        let id = String(extra.dropFirst("viewers:".count))
        guard let ids = TelegramData.ids(id), let index = messages[ids.chat]?.firstIndex(where: { $0.id == id }) else { return }
        // In a private chat (user 0) the reader is the chat itself, unnamed, as every app's private chat shows it.
        let readers = viewers.filter { $0.user != meID }.map { viewer in
            viewer.user == 0 ? ChatReader(name: "", receipt: .read, date: viewer.date)
                : ChatReader(name: users[viewer.user] ?? String(viewer.user), receipt: .read, date: viewer.date, key: String(viewer.user))
        }
        guard messages[ids.chat]?[index].readers != readers else { return }
        messages[ids.chat]?[index].readers = readers
        changed.insert(ids.chat)
    }

    /// Tells Telegram you read the chat, after your own click: its newest messages count as viewed, so the chat is read
    /// on your phone too and the people who wrote see it. Telegram's own unread count follows by itself; a refusal
    /// shows as a toast, as every other chat action's does.
    func markRead(chat: Int64) throws {
        let ids = (messages[chat] ?? []).filter { !$0.isMine }.suffix(100).compactMap { TelegramData.ids($0.id)?.message }
        // Nothing Telegram knows by its id (a chat only its notifications brought): saying it was read would be untrue.
        guard !ids.isEmpty else { throw NookError(tr("chats.markReadInApp.nothing", "Telegram", "Telegram")) }
        try act(["@type": "viewMessages", "chat_id": chat, "message_ids": ids, "force_read": true], chat: chat)
    }

    /// Your vote on a poll, after your own click (an empty choice takes it back); the poll shows it at once.
    func vote(_ choice: [String], message id: String) throws {
        guard let ids = TelegramData.ids(id), let index = messages[ids.chat]?.firstIndex(where: { $0.id == id }),
              let poll = messages[ids.chat]?[index].poll else { throw NookError(tr("chat.poll.failed")) }
        let options = poll.options.indices.filter { choice.contains(poll.options[$0].text) }
        try act(["@type": "setPollAnswer", "chat_id": ids.chat, "message_id": ids.message, "option_ids": options], chat: ids.chat)
        messages[ids.chat]?[index].poll = poll.voting(choice)
        changed.insert(ids.chat)
    }

    /// Your emoji on a message (its id in Nook), after your own click; the same one again takes it back. The chat
    /// shows it once Telegram has it; a refusal (an emoji the chat does not allow) shows as a toast.
    func react(_ emoji: String, to id: String, mine: Bool) throws {
        guard isReady, let ids = TelegramData.ids(id) else { throw NookError(tr("chat.compose.telegramOff")) }
        try act(TelegramData.reaction(emoji, chat: ids.chat, message: ids.message, add: !mine), chat: ids.chat)
    }

    // MARK: Chat actions

    /// Whether the chat is pinned at the top of Telegram's main chat list.
    func isPinned(_ chat: Int64) -> Bool { chats[chat]?.isPinned ?? false }

    /// Whether the chat's notifications are muted.
    func isMuted(_ chat: Int64) -> Bool { chats[chat]?.isMuted ?? false }

    /// Pins the chat in Telegram's main list, or unpins it, after your own click; Nook shows it at once.
    func setPinned(_ pinned: Bool, chat: Int64) throws {
        try act(TelegramData.togglePinned(pinned, chat: chat), chat: chat)
        chats[chat]?.isPinned = pinned
    }

    /// Mutes the chat for good, or unmutes it, after your own click; its other notification settings stay.
    func setMuted(_ muted: Bool, chat: Int64) throws {
        try act(TelegramData.setMuted(muted, chat: chat, current: notificationSettings[chat]), chat: chat)
        chats[chat]?.isMuted = muted
        notificationSettings[chat]?["use_default_mute_for"] = false
        notificationSettings[chat]?["mute_for"] = muted ? TelegramData.muteForever : 0
    }

    /// Moves the chat to Telegram's archive; a new message brings it back, as in the Telegram app.
    func archive(_ chat: Int64) throws {
        try act(TelegramData.archive(chat: chat), chat: chat)
    }

    /// The new text of your message (its id in Nook); the chat shows it once Telegram has it (`updateMessageContent`).
    func edit(_ id: String, to text: String) throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        guard let ids = TelegramData.ids(id) else { throw NookError(tr("chat.compose.telegramOff")) }
        try act(TelegramData.editMessageText(chat: ids.chat, message: ids.message, text: body), chat: ids.chat)
    }

    /// Deletes your message (its id in Nook) for everyone; the chat drops it once Telegram did (`updateDeleteMessages`).
    func delete(_ id: String, forEveryone: Bool = true) throws {
        guard let ids = TelegramData.ids(id) else { throw NookError(tr("chat.compose.telegramOff")) }
        try act(TelegramData.deleteMessages(chat: ids.chat, messages: [ids.message], revoke: forEveryone), chat: ids.chat)
    }

    /// Sends a chat action to TDLib, with an `@extra` so a refusal shows as a toast.
    private func act(_ request: [String: Any], chat: Int64) throws {
        guard isReady, client != nil, chats[chat] != nil else { throw NookError(tr("chat.compose.telegramOff")) }
        actionCount += 1
        var request = request
        request["@extra"] = "action:\(actionCount):\(chat)"
        send(request)
    }

    // MARK: Sending

    /// The chat Nook shows under this name, newest first when two share it.
    func chatID(named name: String) -> Int64? {
        chats.values.filter { $0.title == name && shown.contains($0.id) }.max { $0.order < $1.order }?.id
            ?? chats.values.first { $0.title == name }?.id
    }

    /// Sends what you typed to a chat, as an answer to `replyTo` (a message's id in Nook) when set. The chat shows it
    /// once Telegram has it; a refusal shows as a toast.
    func send(text: String, to chat: Int64, replyTo: String? = nil) throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        try request(TelegramData.textContent(body), legacy: nil, chat: chat, replyTo: replyTo)
    }

    /// Sends a file, a poll, a place or a contact card to a chat, as `send(text:)` does.
    func send(_ outgoing: ChatOutgoing, to chat: Int64, replyTo: String? = nil) throws {
        if case .file(let file) = outgoing, file.tooLarge { throw NookError(tr("chat.compose.tooLarge", file.name)) }
        let content = TelegramData.content(outgoing)
        let legacy = TelegramData.content(outgoing, legacy: true)
        try request(content, legacy: NSDictionary(dictionary: legacy).isEqual(to: content) ? nil : legacy, chat: chat,
                    replyTo: replyTo)
    }

    private func request(_ content: [String: Any], legacy: [String: Any]?, chat: Int64, replyTo: String?) throws {
        guard isReady, chats[chat] != nil else { throw NookError(tr("chat.compose.telegramOff")) }
        sendCount += 1
        let extra = "send:\(sendCount)"
        let answered = replyTo.flatMap(TelegramData.ids).flatMap { $0.chat == chat ? $0.message : nil }
        if let legacy {
            sending[extra] = (TelegramData.sendMessage(chat: chat, content: legacy, replyTo: answered, extra: extra + ":legacy"), nil)
        }
        send(TelegramData.sendMessage(chat: chat, content: content, replyTo: answered, extra: extra))
        shown.insert(chat)
    }

    /// TDLib refused a message Nook sent: an older TDLib is asked again in its own shape; else a toast says why.
    private func refused(_ extra: String, _ reason: String) {
        let key = extra.hasSuffix(":legacy") ? String(extra.dropLast(":legacy".count)) : extra
        let pending = sending.removeValue(forKey: key)
        if !extra.hasSuffix(":legacy"), let legacy = pending?.legacy {
            sending[key] = (nil, reason)
            send(legacy)
            return
        }
        ToastCenter.shared.error(tr("chat.compose.notSent"), detail: Self.explain(pending?.error ?? reason))
    }

    /// A chat's picture, downloaded once when TDLib does not have it yet.
    private func fetchPicture(of chat: Int64) {
        guard let file = chats[chat]?.photo, chats[chat]?.avatar == nil, pictures[file] == nil else { return }
        pictures[file] = chat
        send(["@type": "downloadFile", "file_id": file, "priority": 1, "offset": 0, "limit": 0, "synchronous": true])
    }

    /// A file TDLib finished downloading: the message it belongs to shows it from now on.
    private func downloaded(_ file: Int64, path: String) {
        if let chat = pictures.removeValue(forKey: file) {
            chats[chat]?.avatar = path
            changed.insert(chat)
            return
        }
        guard let owner = downloads.removeValue(forKey: file),
              let index = messages[owner.chat]?.firstIndex(where: { $0.id == owner.message }) else { return }
        messages[owner.chat]?[index].media?.path = path
        changed.insert(owner.chat)
    }

    /// TDLib's error codes in words: PHONE_CODE_INVALID, PASSWORD_HASH_INVALID…
    private static func explain(_ message: String) -> String {
        switch message {
        case "PHONE_NUMBER_INVALID": return tr("chats.telegram.error.phone")
        case "PHONE_CODE_INVALID", "PHONE_CODE_EMPTY": return tr("chats.telegram.error.code")
        case "PHONE_CODE_EXPIRED": return tr("chats.telegram.error.expired")
        case "PASSWORD_HASH_INVALID": return tr("chats.telegram.error.password")
        case "API_ID_INVALID", "API_ID_PUBLISHED_FLOOD": return tr("chats.telegram.error.keys")
        default: return message
        }
    }
}

/// TDLib's JSON client in Nook's own process: requests go in as JSON strings, every answer and update comes back on a
/// thread of its own and is handed over as a JSON object.
final class TDLibClient: @unchecked Sendable {
    private typealias CreateClient = @convention(c) () -> Int32
    private typealias Send = @convention(c) (Int32, UnsafePointer<CChar>) -> Void
    private typealias Receive = @convention(c) (Double) -> UnsafePointer<CChar>?
    private typealias Execute = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?

    private let id: Int32
    private let sendFunction: Send
    private let lock = NSLock()
    private var running = true

    init(library: URL, onUpdate: @escaping @Sendable ([String: Any]) -> Void) throws {
        guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
            throw NookError(tr("chats.telegram.loadFailed", dlerror().map { String(cString: $0) } ?? ""))
        }
        guard let create = dlsym(handle, "td_create_client_id"), let send = dlsym(handle, "td_send"),
              let receive = dlsym(handle, "td_receive"), let execute = dlsym(handle, "td_execute") else {
            throw NookError(tr("chats.telegram.loadFailed", "td_create_client_id"))
        }
        let executeFunction = unsafeBitCast(execute, to: Execute.self)
        // TDLib's own log only for its errors: nothing of the chats is written there.
        _ = executeFunction(#"{"@type":"setLogVerbosityLevel","new_verbosity_level":1}"#)
        id = unsafeBitCast(create, to: CreateClient.self)()
        sendFunction = unsafeBitCast(send, to: Send.self)
        let receiveFunction = unsafeBitCast(receive, to: Receive.self)
        let client = id
        let thread = Thread { [weak self] in
            while self?.isRunning ?? false {
                guard let answer = receiveFunction(1.0) else { continue }
                let text = String(cString: answer)
                guard let object = TelegramData.object(text) else { continue }
                if let from = TelegramData.int64(object["@client_id"]), from != Int64(client) { continue }
                onUpdate(object)
            }
        }
        thread.name = "TDLib"
        thread.start()
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func send(_ json: String) {
        json.withCString { sendFunction(id, $0) }
    }

    /// Closes the session cleanly; TDLib then stops sending.
    func close() {
        send(#"{"@type":"close"}"#)
        lock.lock(); running = false; lock.unlock()
    }
}
