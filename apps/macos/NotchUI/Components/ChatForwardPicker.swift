import SwiftUI

/// Sending a message on to other chats, over the open chat: the message small on top, a search, and every chat Nook
/// can write in (of every app, newest first) to tick. A chat that cannot take the message's file shows dimmed with why.
/// Nothing goes until you click Forward; Escape or Cancel closes it. The same for every chat app: each chat's own route
/// sends it (`AppModel.forwardChatMessage`).
struct ChatForwardPicker: View {
    /// One chat to send to, and whether it can take this message.
    struct Target: Identifiable {
        let entry: ChatsEntry
        let fits: Bool
        var id: String { entry.id }
    }

    /// What the message says, as its quote shows it.
    let quote: BubbleQuote
    let targets: [Target]
    let onCancel: () -> Void
    let onForward: ([ChatsEntry]) -> Void
    @State private var query = ""
    @State private var chosen: [String] = []
    @FocusState private var searching: Bool

    private var shown: [Target] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return targets }
        return targets.filter {
            $0.entry.name.localizedCaseInsensitiveContains(query)
                || (MessagingApps.app(id: $0.entry.app)?.name ?? $0.entry.app).localizedCaseInsensitiveContains(query)
        }
    }

    private func forward() {
        let picked = chosen.compactMap { id in targets.first { $0.id == id && $0.fits }?.entry }
        guard !picked.isEmpty else { return }
        onForward(picked)
    }

    var body: some View {
        ZStack {
            NookTheme.ink.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Text(tr("chat.forward.title"))
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                    .accessibilityAddTraits(.isHeader)
                QuotedMessage(quote: quote)
                NookSearchField(prompt: tr("chat.forward.search"), text: $query, style: .inline, focus: $searching,
                                onSubmit: forward, onEscape: onCancel)
                list
                HStack(spacing: NookTheme.Spacing.sm) {
                    Spacer(minLength: 0)
                    SmallGhostButton(title: tr("button.cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    SmallPrimaryButton(title: chosen.count > 1 ? tr("chat.forward.sendMany", chosen.count) : tr("chat.forward"),
                                       systemName: "arrowshape.turn.up.right", action: forward)
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty)
                }
            }
            .padding(NookTheme.Spacing.xl)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.sheet, style: .continuous).fill(NookTheme.surface))
            .padding(NookTheme.Spacing.xl)
        }
        .onAppear { searching = true }
    }

    @ViewBuilder
    private var list: some View {
        let shown = self.shown
        if shown.isEmpty {
            ListEmptyNote(tr(targets.isEmpty ? "chat.forward.none" : "chat.forward.noMatch"))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, target in
                        if index > 0 { NookRowSeparator() }
                        ChatForwardRow(entry: target.entry, fits: target.fits, chosen: chosen.contains(target.id)) {
                            withAnimation(NookTheme.hover) {
                                if let at = chosen.firstIndex(of: target.id) { chosen.remove(at: at) } else { chosen.append(target.id) }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }
}

/// One chat in the forward list: its face, its name and app, and a tick once chosen.
private struct ChatForwardRow: View {
    let entry: ChatsEntry
    let fits: Bool
    let chosen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var appName: String { MessagingApps.app(id: entry.app)?.name ?? entry.app }

    private var photo: NSImage? {
        if let avatar = entry.avatar, let image = ChatAvatarImages.shared.image(avatar) { return image }
        return ContactPhotos.shared.photo(handle: entry.handle, name: entry.name)
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: NookTheme.Spacing.md) {
                ChatsAvatar(name: entry.name, app: entry.app, photo: photo, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(fits ? (entry.account.map { appName + " · " + $0 } ?? appName) : tr("chat.forward.cannotTake", appName))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(NookTheme.font(15))
                    .foregroundStyle(chosen ? NookTheme.paper : (hovering ? NookTheme.textSecondary : NookTheme.textTertiary))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, NookTheme.Spacing.sm)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(NookTheme.rowFill(selected: chosen, hovering: hovering)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!fits)
        .opacity(fits ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
