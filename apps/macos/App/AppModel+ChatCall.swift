import AppKit
import UniformTypeIdentifiers

// Calling from a chat, the same for every chat app (`ChatCalls`): the app itself holds the call, Nook starts it there and
// follows it (`ChatCallCenter`).
extension AppModel {
    /// Who a call from this chat goes to: the number, address and username its app told (else the chat's own number).
    func chatCallPerson(_ entry: ChatsEntry) -> ChatCallPerson {
        let isGroup = entry.kind == .group || (entry.members?.count ?? 0) > 1
        return ChatCallPerson(app: entry.app, name: entry.name, phone: chatPhone(entry), email: entry.profile?.email,
                              username: entry.profile?.username, isGroup: isGroup)
    }

    /// The chat's phone number, as its app says it or as the chat is known by; nil for a group.
    func chatPhone(_ entry: ChatsEntry) -> String? {
        guard entry.kind != .group else { return nil }
        if let phone = ChatProfile.text(entry.profile?.phone) { return phone }
        return entry.handle.flatMap(ChatCalls.phoneDigits)
    }

    /// Whether this chat's app holds calls Nook can start.
    func canCallChat(_ entry: ChatsEntry) -> Bool {
        ChatCalls.launch(.voice, for: chatCallPerson(entry)) != nil
    }

    /// FaceTime as another way to call this person: where their number or address is known, outside Messages (whose
    /// own calls are FaceTime already).
    func chatFaceTimeHandle(_ entry: ChatsEntry) -> String? {
        guard entry.app != "messages", entry.kind != .group else { return nil }
        return chatPhone(entry) ?? ChatProfile.text(entry.profile?.email)
    }

    /// Starts a call in the chat's app (or with FaceTime) after your click, logs it, and follows it.
    func startChatCall(_ entry: ChatsEntry, kind: ChatCallKind, faceTime: Bool = false) {
        let appName = MessagingApps.app(id: entry.app)?.name ?? entry.app
        let launch: ChatCallLaunch?
        if faceTime {
            launch = ChatCalls.faceTime(kind, handle: chatFaceTimeHandle(entry)).map(ChatCallLaunch.direct)
        } else {
            launch = ChatCalls.launch(kind, for: chatCallPerson(entry))
        }
        guard let launch else { return }
        let viaFaceTime = faceTime || entry.app == "messages" && launch.isDirect
        let workspace = NSWorkspace.shared
        var opened = false
        if let url = launch.url, workspace.urlForApplication(toOpen: url) != nil {
            opened = workspace.open(url)
        }
        if !opened {
            guard !viaFaceTime else { return }
            openChatAppForCall(entry.app)
        }
        store.audit(tool: "chat_call", args: "\(viaFaceTime ? "FaceTime" : appName): \(entry.name)",
                    result: kind == .video ? "video" : "voice")
        ChatCallCenter.shared.begin(entry: entry, appName: viaFaceTime ? "FaceTime" : appName, kind: kind,
                                    direct: opened && launch.isDirect, bundles: callBundles(entry.app, faceTime: viaFaceTime))
    }

    /// The Mac app, else the website in the browser: a call needs the microphone and camera, which the app view inside
    /// Nook does not hand to the site.
    private func openChatAppForCall(_ appID: String) {
        let workspace = NSWorkspace.shared
        let source = MessagingApps.app(id: appID)
        if let url = source?.bundleIDs.lazy.compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.openApplication(at: url, configuration: configuration) { _, _ in }
        } else if let host = source?.domains.first ?? source?.site, let site = URL(string: "https://" + host) {
            workspace.open(site)
        }
    }

    /// The apps whose microphone means the call is on: FaceTime's, the Mac app's, or a browser's for a web-only app.
    private func callBundles(_ appID: String, faceTime: Bool) -> [String] {
        if faceTime { return ChatCalls.faceTimeBundles }
        let workspace = NSWorkspace.shared
        let installed = (MessagingApps.app(id: appID)?.bundleIDs ?? []).filter { workspace.urlForApplication(withBundleIdentifier: $0) != nil }
        if !installed.isEmpty { return installed }
        return ["com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
                "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen"]
    }

    /// Writes the chat's messages to a text file you pick.
    func exportChat(_ entry: ChatsEntry) {
        guard let thread = ChatCaptureService.shared.loadedInbox.threads[entry.id] else { return }
        let panel = NSSavePanel()
        let safe = entry.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        panel.nameFieldStringValue = safe + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        let app = MessagingApps.app(id: entry.app)?.name ?? entry.app
        let text = "\(entry.name) · \(app)\n\n" + ChatInbox.transcript(thread, limit: .max) + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            store.audit(tool: "chat_export", args: "\(app): \(entry.name)", result: url.lastPathComponent)
        } catch {
            viewModel.present(errorCard(error.localizedDescription))
        }
    }
}
