import SwiftUI

/// What Nook may do by itself (`NookAccess`), as a choice in the composer: the chat's and the Double Tap field's
/// counterpart of an agent's access menu, with the same pill and rows. ⇧Tab moves to the next level while `focused`
/// (the composer it sits in has the keyboard).
struct NookAccessMenu: View {
    var focused = false
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let access = settings.nookAccess
        ComposerDropdown(width: 320) {
            ComposerPill(symbol: access.symbol, text: access.label, short: access.short,
                         tint: access == .more ? NookTheme.coralSoft : nil)
        } content: {
            DropdownHeader(title: tr("nookAccess.title"))
            ForEach(NookAccess.allCases) { level in
                DropdownRow(symbol: level.symbol, title: level.label, detail: level.detail, chosen: level == access,
                            tint: level == .more ? NookTheme.coralSoft : nil) {
                    settings.nookAccess = level
                }
            }
        }
        .help(access.detail + " · " + tr("nookAccess.switch"))
        .keyCommands(["composer.access": {
            settings.nookAccess = settings.nookAccess.next
            return true
        }], enabled: focused)
    }
}
