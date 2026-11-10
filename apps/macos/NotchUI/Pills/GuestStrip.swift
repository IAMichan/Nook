import SwiftUI

/// A shared session above the composer (see `GuestShares`): that a guest link works and until when, how many follow, and what
/// guests wrote. A guest's message goes nowhere until you send it; dismissing removes it and its files.
struct GuestStrip: View {
    let id: UUID
    @ObservedObject var shares: GuestShares

    var body: some View {
        if let until = shares.shared[id] {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                AdaptiveActionRow {
                    HStack(spacing: NookTheme.Spacing.md) {
                        Image(icon: "person.badge.shield.checkmark").font(NookTheme.font(11, .semibold))
                        Text(status(until)).foregroundStyle(NookTheme.textSecondary).lineLimit(2)
                    }
                } actions: {
                    CopyGhostButton(title: tr("guest.copy")) { shares.link(id) ?? "" }
                    SmallGhostButton(title: tr("guest.stop")) { shares.stop(id) }
                }
                ForEach(shares.held[id] ?? []) { message in
                    AdaptiveActionRow {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            Text(tr("guest.held.from")).foregroundStyle(NookTheme.amber)
                            if !message.text.isEmpty {
                                Text(message.text).foregroundStyle(NookTheme.paper).lineLimit(6)
                            }
                            if !message.files.isEmpty {
                                Text(message.files.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                                    .foregroundStyle(NookTheme.textTertiary).lineLimit(2)
                            }
                        }
                    } actions: {
                        SmallPrimaryButton(title: tr("guest.send")) { shares.sendHeld(id, message: message.id) }
                        SmallGhostButton(title: tr("guest.dismiss")) { shares.dismissHeld(id, message: message.id) }
                    }
                }
            }
            .font(NookTheme.TextStyle.detail)
        }
    }

    private func status(_ until: Date) -> String {
        let time = until.formatted(date: .omitted, time: .shortened)
        let count = shares.watching[id] ?? 0
        switch count {
        case 0: return tr("guest.sharing", time)
        case 1: return tr("guest.sharing.one", time)
        default: return tr("guest.sharing.many", time, count)
        }
    }
}
