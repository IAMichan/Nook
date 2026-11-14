import SwiftUI

/// The shortcut cheat sheet (`?`, or ⌘/): every command with the keys it answers to now, in groups, with a filter. It reads
/// the live rules (`KeyCommandCenter`), so a key remapped in Settings › Shortcuts shows here at once. A row's key is a
/// click away from remapping: "Change keys" opens Settings › Shortcuts. Escape or a click beside it closes it.
struct ShortcutCheatSheetView: View {
    let close: () -> Void
    let openSettings: () -> Void

    @State private var filter = ""
    @FocusState private var focused: Bool

    private var sheet: ShortcutCheatSheet { ShortcutCheatSheet(effective: KeyCommandCenter.shared.rules) }

    var body: some View {
        let sheet = self.sheet
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(tr("cheatsheet.title")).font(NookTheme.TextStyle.title).foregroundStyle(NookTheme.paper)
                Spacer()
                Button(tr("cheatsheet.change"), action: openSettings)
                    .buttonStyle(.nookPlain).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.iris)
                ToolbarIconButton("xmark", tr("button.close"), height: 24, width: 24) { close() }
            }
            .padding(NookTheme.Spacing.lg)
            NookSearchField(prompt: tr("cheatsheet.filter"), text: $filter, focus: $focused, onEscape: close)
                .padding(.horizontal, NookTheme.Spacing.lg)
            NookDivider().padding(.top, NookTheme.Spacing.md)
            ScrollView {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                    let shown = sheet.filtered(filter) { tr("keys.command." + $0) }
                    ForEach(ShortcutCheatSheet.Group.allCases, id: \.self) { group in
                        let rows = shown.filter { $0.group == group }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                                Text(tr("cheatsheet.group." + group.rawValue))
                                    .font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
                                ForEach(rows) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                                        Text(tr("keys.command." + row.command))
                                            .font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(row.keys.joined(separator: "  "))
                                            .font(NookTheme.TextStyle.code).foregroundStyle(NookTheme.textSecondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text(tr("cheatsheet.none")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .padding(NookTheme.Spacing.lg)
            }
            .frame(maxHeight: 440)
        }
        .frame(maxWidth: .infinity)
        .frame(maxWidth: 560)
        .cardBackground(NookTheme.graphite, stroke: NookTheme.line2, radius: NookTheme.Radius.sheet)
        .padding(.horizontal, NookTheme.Spacing.lg)
        .focusOnAppear($focused)
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("cheatsheet.title"))
    }
}

/// Shows the cheat sheet over a window and answers its `shortcuts.cheatSheet` key (`?`, ⌘/), again to close it.
private struct ShortcutCheatSheetHost: ViewModifier {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if app.cheatSheetOpen, !app.demoMode {
                    ZStack(alignment: .top) {
                        // A click beside the sheet closes it, as Escape does.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { app.cheatSheetOpen = false }
                            .accessibilityHidden(true)
                        ShortcutCheatSheetView(close: { app.cheatSheetOpen = false }, openSettings: {
                            app.cheatSheetOpen = false
                            app.openSettings(section: .shortcuts)
                        })
                        .padding(.top, NookTheme.Spacing.xxxl)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
                    }
                }
            }
            .animation(NookTheme.reveal, value: app.cheatSheetOpen)
            .keyCommand("shortcuts.cheatSheet", enabled: !app.demoMode) { app.cheatSheetOpen.toggle() }
    }
}

extension View {
    func shortcutCheatSheet() -> some View { modifier(ShortcutCheatSheetHost()) }
}
