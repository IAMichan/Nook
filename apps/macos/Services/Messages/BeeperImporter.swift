import Foundation
import AppKit
import Security

/// Moves someone from Beeper to Nook, once, after their own click in Settings › Chats (see `BeeperImport` for what
/// comes over and what cannot). It reads Beeper Desktop's local API with the token Nook already kept for it, or one
/// pasted in Settings, and nothing else: the API is on this Mac. When the move is done the token is forgotten and Nook
/// never asks Beeper again.
@MainActor
final class BeeperImporter: ObservableObject {
    static let shared = BeeperImporter()

    /// The accounts Beeper has, once read.
    @Published private(set) var accounts: [BeeperImport.Account] = []
    /// How many chats came over with their history, and how many chats' settings wait for their app; nil until read.
    @Published private(set) var imported: (chats: Int, settings: Int)?
    @Published private(set) var isBusy = false
    /// Why Beeper could not be read, in a sentence; nil while it works.
    @Published private(set) var problem: String?
    @Published private(set) var hasToken = CloudHelp.secret(BeeperImport.tokenAccount) != nil
    @Published private(set) var isDone = UserDefaults.standard.bool(forKey: BeeperImporter.doneKey)

    private static let doneKey = "beeperImport.done"
    private static let settingsKey = "beeperImport.settings"
    /// WhatsApp went through Beeper: the move offers linking it in Nook.
    static let wasGatewayKey = "beeperImport.wasWhatsAppGateway"

    /// Beeper is on this Mac, or Nook read it before: the move is offered until it is done.
    var isOffered: Bool {
        !isDone && (hasToken || UserDefaults.standard.bool(forKey: Self.wasGatewayKey)
                    || NSWorkspace.shared.urlForApplication(withBundleIdentifier: BeeperImport.bundleID) != nil)
    }

    /// The apps to link in Nook: those of Beeper's accounts, with WhatsApp when it went through Beeper.
    var apps: [String] {
        var apps = BeeperImport.apps(accounts)
        if UserDefaults.standard.bool(forKey: Self.wasGatewayKey), !apps.contains("whatsapp") { apps.insert("whatsapp", at: 0) }
        return apps
    }

    // MARK: Settings from before

    /// At launch, before WhatsApp starts: a WhatsApp that went through Beeper links in Nook's own way from now on. Its
    /// token is kept for the move, and WhatsApp stays off until you link it again (a QR code from your phone), so
    /// nothing starts by itself.
    static func migrateSettings() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "whatsappGateway") == "beeper" else { return }
        if CloudHelp.secret(BeeperImport.tokenAccount) == nil, let token = WhatsAppSettings.credential {
            Keychain.write(token, account: BeeperImport.tokenAccount)
        }
        Keychain.remove(WhatsAppSettings.credentialAccount)
        defaults.removeObject(forKey: "whatsappURL")
        WhatsAppSettings.gateway = .gowa
        WhatsAppSettings.enabled = false
        defaults.set(true, forKey: wasGatewayKey)
    }

    // MARK: The move

    /// Keeps the token pasted in Settings, to read Beeper with.
    func saveToken(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, Keychain.write(value, account: BeeperImport.tokenAccount) == errSecSuccess else { return false }
        hasToken = true
        problem = nil
        return true
    }

    /// Reads Beeper and brings over what it can, after your own click: the apps are switched on (collecting with them),
    /// the chats come into the Chats tab with their recent history, and the pinned, muted and archived chats are kept
    /// for when their app is linked in Nook.
    func run(setCollecting: (Bool) -> Void) async {
        guard let token = CloudHelp.secret(BeeperImport.tokenAccount), !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        problem = nil
        do {
            accounts = BeeperImport.accounts(try await Self.json("/v1/accounts", token: token))
            let listed = try await Self.json("/v1/chats", ["limit": String(BeeperImport.chatCount)], token: token)
            let list = listed as? [String: Any] ?? [:]
            var chats: [BridgedChat] = []
            for chat in ChatServiceData.chats(list) where !BeeperImport.ownHistory.contains(chat.app) {
                let answer = try await Self.json("/v1/chats/" + ChatJSON.segment(chat.id) + "/messages",
                                                 ["limit": String(BeeperImport.history)], token: token)
                let messages = BeeperImport.history(ChatServiceData.messages(answer as? [String: Any] ?? [:], chat: chat))
                guard !messages.isEmpty else { continue }
                // The unread count stays Nook's: these chats were read (or not) in Beeper, not here.
                chats.append(BridgedChat(app: chat.app, name: chat.title, messages: messages, unread: nil,
                                         members: chat.members.isEmpty ? nil : chat.members))
            }
            let capture = ChatCaptureService.shared
            for app in apps { capture.setSource(app, on: true) }
            if !capture.enabled { setCollecting(true) }
            let brought = capture.importChats(chats)
            // Only the apps Nook's chat helper links can have a chat pinned, muted or archived from Nook.
            let new = BeeperImport.settings(list).filter { ChatHelper.apps.contains($0.app) }
            settings = BeeperImport.merged(settings, new)
            imported = (brought, new.count)
            AppModel.shared.store.audit(tool: "beeper_import", args: apps.joined(separator: ", "),
                                        result: "\(brought) chats, \(new.count) settings")
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The move is done: Beeper's token is forgotten and Settings no longer offers it. The settings that wait for their
    /// app stay, so linking an app later still brings them.
    func finish() {
        Keychain.remove(BeeperImport.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.wasGatewayKey)
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        hasToken = false
        isDone = true
        accounts = []
        imported = nil
    }

    // MARK: Chat settings, once their app is linked

    /// What Beeper had set for chats whose app is not linked in Nook yet.
    private(set) var settings: [BeeperImport.ChatSetting] {
        get {
            UserDefaults.standard.data(forKey: Self.settingsKey)
                .flatMap { try? JSONDecoder().decode([BeeperImport.ChatSetting].self, from: $0) } ?? []
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.settingsKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.settingsKey)
            }
        }
    }

    /// Does in the chats the helper lists what Beeper had set for them (pin, mute, archive), each once, and logs it as
    /// your own change. Returns the ids of the chats it archived, which leave the list.
    func apply(to chats: [ChatServiceData.Chat], in bridge: ChatServiceBridge) async -> Set<String> {
        var waiting = settings
        guard !waiting.isEmpty else { return [] }
        var archived: Set<String> = []
        for chat in chats {
            let key = ChatInbox.key(app: chat.app, chat: chat.title)
            guard let setting = waiting.first(where: { $0.key == key }) else { continue }
            // Off the list first: a change the app refuses is not tried again at every read.
            waiting.removeAll { $0.key == key }
            settings = waiting
            let change = BeeperImport.change(setting, for: chat)
            guard !change.isEmpty else { continue }
            do {
                if change.pin { try await bridge.setPinned(true, chat: chat.id) }
                if change.mute { try await bridge.setMuted(true, chat: chat.id) }
                if change.archive {
                    try await bridge.archive(chat.id)
                    archived.insert(chat.id)
                }
                AppModel.shared.store.audit(tool: "beeper_import_setting", args: chat.title,
                                            result: [change.pin ? "vastgezet" : nil, change.mute ? "gedempt" : nil,
                                                     change.archive ? "gearchiveerd" : nil].compactMap { $0 }.joined(separator: ", "))
            } catch {
                Log.connectors.info("Chats: a chat setting from Beeper could not be applied")
            }
        }
        settings = BeeperImport.merged(waiting, [])
        return archived
    }

    // MARK: Beeper's API

    private static func json(_ path: String, _ parameters: [String: String] = [:], token: String) async throws -> Any? {
        var components = URLComponents(url: BeeperImport.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        if !parameters.isEmpty { components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw NookError(tr("beeper.import.unreachable")) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ConnectorHTTP.session.data(for: request)
        } catch {
            throw NookError(tr("beeper.import.unreachable"))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw NookError(tr("beeper.import.unauthorized")) }
        guard (200..<300).contains(code) else {
            throw NookError(tr("beeper.import.failed", ChatServiceData.errorMessage(data) ?? "HTTP \(code)"))
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
