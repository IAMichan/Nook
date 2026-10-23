import Foundation

/// Linking a chat app (Instagram, WhatsApp, Telegram, Teams…) from Settings › Chats › Linked chats, through the local
/// chat service on this Mac that `BeeperBridge` reads: which apps it can link and with which accounts (/v1/bridges), and
/// the steps of one login (/v1/bridges/{id}/login-sessions). Foundation only, so it can be tested anywhere; `ChatLinker`
/// makes the calls and Settings shows the steps.
enum ChatLinkData {
    /// One app the service can link, with the accounts already linked in it.
    struct Network: Equatable, Identifiable, Sendable {
        /// The service's id for it ("local-whatsapp"): where its logins start.
        var id: String
        /// The app in Nook (`MessagingApp.id`).
        var app: String
        var name: String
        /// It can link an account now; false while it is at its limit, temporarily unavailable or switched off.
        var canLink: Bool
        var accounts: [Account]
    }

    struct Account: Equatable, Identifiable, Sendable {
        var id: String
        /// The login it belongs to, for unlinking it.
        var login: String?
        /// Who is signed in: their name, else their username, phone number or email.
        var name: String
        var isConnected: Bool
        /// Why it is not connected, in the service's words ("Reconnect required").
        var status: String?
    }

    /// Where one login stands.
    struct Session: Equatable, Sendable {
        var id: String
        var network: String
        var state: State
        var step: Step?
        /// Why it failed, in the network's own words.
        var problem: String?

        enum State: String, Sendable {
            case waitingForInput = "waiting_for_input"
            case waitingForCookies = "waiting_for_cookies"
            case waitingForDisplay = "waiting_for_display"
            case complete, cancelled, failed
        }

        var isOver: Bool { state == .complete || state == .cancelled || state == .failed }
    }

    /// What the login asks for next.
    enum Step: Equatable, Sendable {
        /// Fields to fill in (a phone number, a code, a password).
        case input(id: String, instructions: String, fields: [Field])
        /// Signing in on the app's own website, in a window Nook opens: what to collect from it once the address matches.
        case browser(id: String, instructions: String, url: URL, userAgent: String?, collect: [Collect], done: String?)
        /// Something to show while the login waits (a QR code to scan, a code to type on the phone).
        case display(id: String, instructions: String, show: Display)
        case complete(instructions: String)

        var id: String? {
            switch self {
            case .input(let id, _, _), .browser(let id, _, _, _, _, _), .display(let id, _, _): return id
            case .complete: return nil
            }
        }

        /// The step's type, as it is sent back with what it asked for.
        var kind: String {
            switch self {
            case .input: return "user_input"
            case .browser: return "cookies"
            case .display: return "display_and_wait"
            case .complete: return "complete"
            }
        }
    }

    struct Field: Equatable, Identifiable, Sendable {
        var id: String
        var label: String
        var placeholder: String
        var initial: String
        var isSecret: Bool
        var isOptional: Bool
    }

    /// A value the browser step collects: a cookie, a header or a local storage key.
    struct Collect: Equatable, Sendable {
        enum Source: String, Sendable { case cookie, header, localStorage = "local_storage" }
        var id: String
        var source: Source
        var name: String
    }

    enum Display: Equatable, Sendable {
        case qr(String)
        case code(String)
        case image(URL)
        case nothing
    }

    // MARK: Reading

    /// The apps of /v1/bridges that Nook knows, one per app (a local one before a cloud one), by name.
    static func networks(_ json: [String: Any]) -> [Network] {
        var byApp: [String: (network: Network, local: Bool)] = [:]
        for bridge in json["items"] as? [[String: Any]] ?? [] {
            guard let id = bridge["id"] as? String, !id.isEmpty else { continue }
            let words = [bridge["type"], bridge["displayName"], bridge["network"], id].compactMap { $0 as? String }.joined(separator: " ")
            guard let app = BeeperData.app(network: words, account: ""), app != "beeper" else { continue }
            let name = MessagingApps.app(id: app)?.name ?? (bridge["displayName"] as? String) ?? id
            let status = bridge["status"] as? String ?? ""
            let network = Network(id: id, app: app, name: name, canLink: status == "available" || status == "connected",
                                  accounts: (bridge["accounts"] as? [[String: Any]] ?? []).compactMap(account))
            let local = bridge["provider"] as? String == "local"
            if let known = byApp[app], known.local || !local {
                // The accounts of both show; links start where the first one runs.
                byApp[app]?.network.accounts += network.accounts
                continue
            }
            var chosen = network
            chosen.accounts += byApp[app]?.network.accounts ?? []
            byApp[app] = (chosen, local)
        }
        return byApp.values.map(\.network).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func account(_ json: [String: Any]) -> Account? {
        guard let id = json["accountID"] as? String, !id.isEmpty else { return nil }
        let user = json["user"] as? [String: Any] ?? [:]
        let name = ["fullName", "username", "phoneNumber", "email"].lazy
            .compactMap { (user[$0] as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? id
        let status = json["status"] as? String ?? ""
        let connected = ["connected", "connecting", "backfilling"].contains(status)
        return Account(id: id, login: json["loginID"] as? String, name: name, isConnected: connected,
                       status: connected ? nil : ((json["statusText"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? status))
    }

    /// A login session as /v1/bridges/{id}/login-sessions answers it.
    static func session(_ json: [String: Any]) -> Session? {
        guard let id = json["loginSessionID"] as? String, let network = json["bridgeID"] as? String,
              let state = Session.State(rawValue: json["status"] as? String ?? "") else { return nil }
        let error = json["error"] as? [String: Any]
        return Session(id: id, network: network, state: state, step: (json["currentStep"] as? [String: Any]).flatMap(step),
                       problem: (error?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func step(_ json: [String: Any]) -> Step? {
        let id = json["stepID"] as? String ?? ""
        let instructions = (json["instructions"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch json["type"] as? String {
        case "user_input":
            guard !id.isEmpty else { return nil }
            let fields: [Field] = (json["fields"] as? [[String: Any]] ?? []).compactMap { field in
                guard let fieldID = field["id"] as? String, !fieldID.isEmpty else { return nil }
                let type = field["type"] as? String ?? "text"
                return Field(id: fieldID, label: (field["label"] as? String) ?? fieldID, placeholder: field["placeholder"] as? String ?? "",
                             initial: field["initialValue"] as? String ?? "", isSecret: type == "password",
                             isOptional: field["optional"] as? Bool == true)
            }
            return .input(id: id, instructions: instructions, fields: fields)
        case "cookies":
            guard !id.isEmpty, let url = (json["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https" else { return nil }
            let collect: [Collect] = (json["fields"] as? [[String: Any]] ?? []).compactMap { field in
                guard let fieldID = field["id"] as? String, !fieldID.isEmpty else { return nil }
                let source = Collect.Source(rawValue: field["type"] as? String ?? "cookie") ?? .cookie
                return Collect(id: fieldID, source: source, name: (field["name"] as? String) ?? fieldID)
            }
            return .browser(id: id, instructions: instructions, url: url, userAgent: json["userAgent"] as? String, collect: collect,
                            done: (json["expectedFinalURLRegex"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case "display_and_wait":
            guard !id.isEmpty else { return nil }
            let display = json["display"] as? [String: Any] ?? [:]
            let show: Display
            switch display["type"] as? String {
            case "qr": show = (display["data"] as? String).map(Display.qr) ?? .nothing
            case "code": show = (display["data"] as? String).map(Display.code) ?? .nothing
            case "emoji": show = (display["imageURL"] as? String).flatMap(URL.init(string:)).map(Display.image) ?? .nothing
            default: show = .nothing
            }
            return .display(id: id, instructions: instructions, show: show)
        case "complete":
            return .complete(instructions: instructions)
        default:
            return nil
        }
    }

    // MARK: Answering

    /// What goes back for a step: its type, and the values it asked for by their ids.
    static func answer(_ step: Step, values: [String: String] = [:], lastURL: String? = nil) -> [String: any Sendable] {
        var body: [String: any Sendable] = ["type": step.kind]
        if !values.isEmpty { body["fields"] = values }
        if case .browser = step {
            body["source"] = "webview"
            if let lastURL { body["lastURL"] = lastURL }
        }
        return body
    }

    /// Whether the browser has reached the address that says the sign-in is done; without a pattern, any page off the
    /// login page counts once every value is there.
    static func isDone(_ address: String, pattern: String?) -> Bool {
        guard let pattern else { return false }
        return address.range(of: pattern, options: .regularExpression) != nil
    }

    /// The values a browser step collects from the cookies there (by name, for the step's host), and the rest by key.
    static func collected(_ collect: [Collect], cookies: [String: String], storage: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for item in collect {
            switch item.source {
            case .cookie: if let value = cookies[item.name], !value.isEmpty { values[item.id] = value }
            case .localStorage: if let value = storage[item.name], !value.isEmpty { values[item.id] = value }
            case .header: break
            }
        }
        return values
    }

    /// Every cookie the step needs is there.
    static func hasCookies(_ collect: [Collect], values: [String: String]) -> Bool {
        let needed = collect.filter { $0.source == .cookie }
        return !needed.isEmpty && needed.allSatisfy { values[$0.id] != nil }
    }
}
