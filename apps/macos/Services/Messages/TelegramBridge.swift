import Foundation
import Combine

/// Telegram with its history, through TDLib: Telegram's own client library, built once with scripts/build-tdlib.sh and
/// shipped inside Nook.app signed like Nook itself, so the hardened runtime and library validation stay on. You log in
/// as on a new phone or computer (your number, the code Telegram sends you, your password when you set one); the
/// session is kept in Nook's support folder and Telegram lists it under Settings › Devices. Read-only: Nook asks for
/// your chats and their messages, nothing else. The app id and hash are your own, from my.telegram.org.
@MainActor
final class TelegramBridge: ObservableObject, ChatBridge {
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

    var isReady: Bool { state == .login(.ready) }
    var isWorking: Bool { isReady }

    static var keys: (id: Int, hash: String)? {
        guard let id = CloudHelp.secret(apiIDAccount).flatMap(Int.init), let hash = CloudHelp.secret(apiHashAccount),
              !hash.isEmpty else { return nil }
        return (id, hash)
    }

    static var libraryURL: URL? {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libtdjson.dylib"),
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
        changed = []
        return ids.compactMap { id in
            guard let chat = chats[id], !chat.title.isEmpty else { return nil }
            let people = (members[id] ?? []).filter { $0 != meID }.compactMap { users[$0] }
            return BridgedChat(app: app, name: chat.title, messages: messages[id] ?? [], unread: chat.unread, avatar: chat.avatar,
                               members: people.isEmpty ? nil : people)
        }
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
            if let chat = (object["chat"] as? [String: Any]).flatMap(TelegramData.chat) {
                chats[chat.id] = chat
                fetchPicture(of: chat.id)
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
        case "updateNewMessage":
            if let message = object["message"] as? [String: Any], let id = TelegramData.int64(message["chat_id"]) {
                add([message], to: id)
                shown.insert(id)
            }
        case "chats":
            // The newest chats of the main list: read each one's history.
            let ids = (object["chat_ids"] as? [Any] ?? []).compactMap { TelegramData.int64($0) }.prefix(Self.chatCount)
            for id in ids {
                shown.insert(id)
                send(["@type": "getChatHistory", "chat_id": id, "from_message_id": 0, "offset": 0,
                      "limit": Self.history, "only_local": false, "@extra": "history:\(id)"])
            }
        case "messages":
            // A chat's history: "history:<id>" the first ask, "history2:<id>" the one before it.
            guard let extra = object["@extra"] as? String else { return }
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
            if object["@extra"] as? String == "login" {
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

    /// Who read your newest messages in a group: asked of Telegram for those it says were read since the last ask.
    /// Telegram answers only for the last week, and in groups of up to 100 people; elsewhere the message keeps its ticks.
    private func askViewers(in chat: Int64) {
        guard let group = chats[chat], group.isGroup, group.readOutbox > 0 else { return }
        let week = Date().addingTimeInterval(-7 * 86_400)
        for message in (messages[chat] ?? []).filter({ $0.isMine && $0.date > week }).suffix(Self.viewed) {
            guard let ids = TelegramData.ids(message.id), ids.message <= group.readOutbox,
                  viewersAsked[message.id] != group.readOutbox else { continue }
            viewersAsked[message.id] = group.readOutbox
            send(["@type": "getMessageViewers", "chat_id": chat, "message_id": ids.message, "@extra": "viewers:\(message.id)"])
        }
        if viewersAsked.count > 500 { viewersAsked.removeAll() }
    }

    /// Telegram's answer to who read one of your messages ("viewers:<message id>"): the message lists them.
    private func viewed(_ viewers: [(user: Int64, date: Date?)], extra: String) {
        let id = String(extra.dropFirst("viewers:".count))
        guard let ids = TelegramData.ids(id), let index = messages[ids.chat]?.firstIndex(where: { $0.id == id }) else { return }
        let readers = viewers.filter { $0.user != meID }.map { viewer in
            ChatReader(name: users[viewer.user] ?? String(viewer.user), receipt: .read, date: viewer.date)
        }
        guard messages[ids.chat]?[index].readers != readers else { return }
        messages[ids.chat]?[index].readers = readers
        changed.insert(ids.chat)
    }

    /// Your vote on a poll, after your own click (an empty choice takes it back); the poll shows it at once.
    func vote(_ choice: [String], message id: String) {
        guard let ids = TelegramData.ids(id), let index = messages[ids.chat]?.firstIndex(where: { $0.id == id }),
              let poll = messages[ids.chat]?[index].poll else { return }
        let options = poll.options.indices.filter { choice.contains(poll.options[$0].text) }
        send(["@type": "setPollAnswer", "chat_id": ids.chat, "message_id": ids.message, "option_ids": options])
        messages[ids.chat]?[index].poll = poll.voting(choice)
        changed.insert(ids.chat)
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
