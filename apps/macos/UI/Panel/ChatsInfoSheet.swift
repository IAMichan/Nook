import SwiftUI

/// A chat's info, the same for every chat app: a click on the chat's name, its face or "Info" in its header opens it.
/// Who it is (their picture, name, number or username), calling them by voice or video in their app (or with FaceTime),
/// what their app said of them (bio, number, address… a group's description and people), the groups you share with
/// them, and what can be done with the chat. Only what the app offers shows (`ChatAbilities`, `ChatCalls`).
struct ChatsInfoSheet: View {
    let entry: ChatsEntry
    @ObservedObject var capture: ChatCaptureService
    /// The chats you pinned in Nook: the row says at once whether this one is.
    @ObservedObject private var pins = ChatPins.shared
    /// Opens another chat (a group you share) in the Chats tab.
    let openChat: (String) -> Void
    /// Runs a change in the chat's app; the chat shows a failure.
    let run: (@escaping () async throws -> Void) -> Void
    /// Removing waits for a yes in the chat: from Nook only (false), or in its app too.
    let remove: (Bool) -> Void
    /// The chat is archived in its app: the chat closes.
    let afterArchive: () -> Void
    let close: () -> Void

    @State private var allGroups = false
    private var app: AppModel { AppModel.shared }
    private var appName: String { MessagingApps.app(id: entry.app)?.name ?? entry.app }
    private var isGroup: Bool { entry.kind == .group || (entry.members?.count ?? 0) > 1 || entry.profile?.admins != nil }

    /// How many shared groups show before "Show all".
    private static let groupsShown = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                identity
                actions
                ChatInfoPanel(name: entry.name, members: ChatInfoButton.sorted(entry.members ?? [], admins: entry.profile?.admins),
                              profile: profileWithPhone, isGroup: isGroup, appName: appName, showsTitle: false,
                              showsNothing: false)
                if !isGroup { commonGroups }
                chatActions
            }
            .padding(NookTheme.Spacing.lg)
        }
        .frame(width: 340, alignment: .leading)
        .frame(maxHeight: 600)
    }

    /// The number the chat is known by shows as its number when its app gave none.
    private var profileWithPhone: ChatProfile {
        var profile = entry.profile ?? ChatProfile()
        if ChatProfile.text(profile.phone) == nil, !isGroup { profile.phone = app.chatPhone(entry) }
        return profile
    }

    private var subtitle: String {
        var parts: [String] = []
        if let phone = app.chatPhone(entry), !isGroup {
            parts.append(phone)
        } else if let username = ChatProfile.text(entry.profile?.username) {
            parts.append(username.hasPrefix("@") ? username : "@" + username)
        }
        parts.append(entry.account.map { appName + " · " + $0 } ?? appName)
        return parts.joined(separator: " · ")
    }

    private var identity: some View {
        VStack(spacing: NookTheme.Spacing.sm) {
            ChatsFace(entry: entry, size: 72)
            Text(entry.name)
                .font(NookTheme.TextStyle.heading)
                .foregroundStyle(NookTheme.paper)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }

    /// Voice and video in the chat's app (where it calls), and opening the app; FaceTime beside it where the number or
    /// address is known.
    @ViewBuilder
    private var actions: some View {
        let calls = app.canCallChat(entry)
        HStack(spacing: NookTheme.Spacing.md) {
            if calls {
                ChatsInfoTile(symbol: "phone", title: tr("chats.call.voiceShort"), help: tr("chats.call.via", appName)) {
                    call(.voice)
                }
                ChatsInfoTile(symbol: "video.fill", title: tr("chats.call.videoShort"), help: tr("chats.call.via", appName)) {
                    call(.video)
                }
            }
            ChatsInfoTile(symbol: "arrow.up.forward.app", title: appName, help: tr("chats.openApp", appName)) {
                close()
                app.openChatApp(entry.app)
            }
        }
        .frame(maxWidth: .infinity)
        if app.chatFaceTimeHandle(entry) != nil {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("chats.call.faceTimeLine"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                Spacer(minLength: NookTheme.Spacing.xs)
                ChatsInfoLink(title: tr("chats.call.voiceShort")) { call(.voice, faceTime: true) }
                ChatsInfoLink(title: tr("chats.call.videoShort")) { call(.video, faceTime: true) }
            }
        }
    }

    private func call(_ kind: ChatCallKind, faceTime: Bool = false) {
        close()
        app.startChatCall(entry, kind: kind, faceTime: faceTime)
    }

    /// The groups of the same app that list this person, from what Nook holds of every chat.
    @ViewBuilder
    private var commonGroups: some View {
        let threads = capture.inbox.threads.values.filter(capture.isShown)
        let groups = ChatCommonGroups.groups(with: entry.name, app: entry.app, in: Array(threads))
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                Text(tr("chats.info.commonGroups", groups.count))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(allGroups ? groups : Array(groups.prefix(Self.groupsShown)), id: \.id) { thread in
                        ChatsInfoGroupRow(entry: ChatsEntry.entry(thread), members: members(thread)) {
                            close()
                            openChat(thread.id)
                        }
                    }
                    if groups.count > Self.groupsShown {
                        ChatsInfoRow(symbol: allGroups ? "chevron.up" : "chevron.down",
                                     title: tr(allGroups ? "chats.info.showLess" : "chats.info.showAll")) {
                            withAnimation(NookTheme.reveal) { allGroups.toggle() }
                        }
                    }
                }
                .background(NookTheme.shape(NookTheme.Radius.card).fill(NookTheme.smoke))
            }
        }
    }

    /// "Arjan, Noah, You".
    private func members(_ thread: InboxThread) -> String {
        (thread.members ?? []).map { $0 == ChatMembership.me ? tr("chat.you") : $0 }.joined(separator: ", ")
    }

    /// Pinning on top of Nook's list (every app), pin, mute and archive in the app where it lets Nook, exporting the chat,
    /// and removing it (from Nook, or in its app).
    @ViewBuilder
    private var chatActions: some View {
        let route = app.chatRoute(for: entry)
        let abilities = app.chatAbilities(route)
        let pinned = pins.isPinned(entry.id)
        VStack(spacing: 0) {
            ChatsInfoRow(symbol: pinned ? "pin.slash" : "pin", title: tr(pinned ? "chats.unpin" : "chats.pin")) {
                pins.toggle(entry.id)
            }
            if let route, abilities.pin {
                ChatsInfoRow(symbol: abilities.pinned ? "pin.slash" : "pin",
                             title: tr(abilities.pinned ? "chats.unpinInApp" : "chats.pinInApp", appName)) {
                    run { try await app.setChatPinned(!abilities.pinned, route: route, name: entry.name) }
                }
            }
            if let route, abilities.mute {
                ChatsInfoRow(symbol: abilities.muted ? "bell" : "bell.slash",
                             title: tr(abilities.muted ? "chats.unmuteInApp" : "chats.muteInApp", appName)) {
                    run { try await app.setChatMuted(!abilities.muted, route: route, name: entry.name) }
                }
            }
            if let route, abilities.archive {
                ChatsInfoRow(symbol: "archivebox", title: tr("chats.archiveInApp", appName)) {
                    close()
                    run {
                        try await app.archiveChat(route: route, thread: app.chatThread(entry), name: entry.name)
                        afterArchive()
                    }
                }
            }
            if capture.inbox.threads[entry.id] != nil {
                ChatsInfoRow(symbol: "square.and.arrow.down", title: tr("chats.info.export")) {
                    close()
                    app.exportChat(entry)
                }
            }
            // No chat app lets another app block or report someone: that stays in the app.
            if !isGroup {
                ChatsInfoRow(symbol: "hand.raised", title: tr("chats.info.blockInApp", appName), tint: NookTheme.coral) {
                    close()
                    app.openChatApp(entry.app)
                }
            }
            if app.chatThread(entry) != nil {
                ChatsInfoRow(symbol: "trash", title: tr("chats.remove"), tint: NookTheme.coral) {
                    close()
                    remove(false)
                }
                if route != nil, abilities.deleteChat {
                    ChatsInfoRow(symbol: "trash", title: tr("chats.deleteInApp", appName), tint: NookTheme.coral) {
                        close()
                        remove(true)
                    }
                }
            }
        }
        .background(NookTheme.shape(NookTheme.Radius.card).fill(NookTheme.smoke))
    }
}

/// One of the small buttons under a chat's name in its info: call, video, open the app.
private struct ChatsInfoTile: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(icon: symbol)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(NookTheme.mint)
                Text(title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 26)
            .background(NookTheme.shape(NookTheme.Radius.control).fill(hovering ? NookTheme.graphite : NookTheme.smoke))
            .overlay(NookTheme.shape(NookTheme.Radius.control).strokeBorder(NookTheme.line2))
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small link-like button ("Call", "Video" after "Or with FaceTime").
private struct ChatsInfoLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.mint)
                .underline(hovering)
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}

/// A row in a chat's info: what it does, in the chat's colors (red for what removes or blocks).
private struct ChatsInfoRow: View {
    let symbol: String
    let title: String
    var tint: Color = NookTheme.mint
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: symbol)
                    .font(NookTheme.font(11, .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(NookTheme.TextStyle.control)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
            .background(NookTheme.shape(NookTheme.Radius.card).fill(hovering ? NookTheme.graphite : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
    }
}

/// A group you share with the person: its face, name and people; a click opens it.
private struct ChatsInfoGroupRow: View {
    let entry: ChatsEntry
    let members: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                ChatsFace(entry: entry, size: 30)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(entry.name)
                        .font(NookTheme.TextStyle.control)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !members.isEmpty {
                        Text(members)
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: NookTheme.Spacing.xs)
                Image(icon: "chevron.right")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .background(NookTheme.shape(NookTheme.Radius.card).fill(hovering ? NookTheme.graphite : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
    }
}
