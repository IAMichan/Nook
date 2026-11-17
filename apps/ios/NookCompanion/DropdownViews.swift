import SwiftUI
import UIKit

// The Mac's composer dropdowns (`ComposerDropdown.swift`) on the phone: the quiet pill as trigger, and instead of a
// system menu Nook's own dark panel with a section header, rows with an icon or logo, a title and a description, a
// faint fill on the chosen row and disabled rows that say why. On an iPhone the panel is a sheet from the bottom, as
// tall as its rows, with rows a thumb can hit; on an iPad it is a popover under the pill, as on the Mac.

/// A composer choice that opens Nook's dropdown panel: a sheet sized to its rows on an iPhone, a popover on an iPad.
struct ComposerDropdown<Trigger: View, Content: View>: View {
    /// The panel's title on an iPhone, where the pill it came from is under the sheet.
    var title: LocalizedStringKey? = nil
    /// The panel's width in a popover (an iPad).
    var width: CGFloat = 300
    @ViewBuilder let trigger: () -> Trigger
    @ViewBuilder let content: () -> Content
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var open = false
    /// A choice that opens something of its own (a photo picker, a file importer) runs once the panel is gone.
    @State private var pending: (() -> Void)?

    var body: some View {
        Button {
            Haptics.tap()
            open = true
        } label: {
            trigger()
        }
        .buttonStyle(PressFade())
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DropdownPanel(title: title, popover: sizeClass == .regular, width: width, content: content)
                .environment(\.closeDropdown, DropdownClose { action in
                    pending = action
                    open = false
                })
                .onDisappear {
                    let action = pending
                    pending = nil
                    action?()
                }
        }
    }
}

/// What a row calls to close its dropdown, with what should happen once it is closed.
struct DropdownClose {
    let run: (_ afterwards: (() -> Void)?) -> Void

    init(_ run: @escaping (_ afterwards: (() -> Void)?) -> Void) { self.run = run }

    func callAsFunction(afterwards: (() -> Void)? = nil) { run(afterwards) }
}

private struct DropdownCloseKey: EnvironmentKey {
    static let defaultValue = DropdownClose { $0?() }
}

extension EnvironmentValues {
    /// Closes the dropdown a row belongs to.
    var closeDropdown: DropdownClose {
        get { self[DropdownCloseKey.self] }
        set { self[DropdownCloseKey.self] = newValue }
    }
}

enum DropdownStyle {
    /// The palette's `menu`, as the Mac's panel: a grey step off the black canvas.
    static let panel = Theme.menu
    static let pressed = Theme.smoke
    static let chosen = Theme.paper.opacity(0.08)
}

/// The panel's frame: a sheet as tall as its rows (scrolling past most of the screen) or a popover of a fixed width.
private struct DropdownPanel<Content: View>: View {
    let title: LocalizedStringKey?
    let popover: Bool
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var rowsHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    /// The most a sheet takes: the rows scroll beyond it.
    private var tallest: CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800
        return screen * 0.8
    }

    var body: some View {
        if popover {
            ScrollView {
                rows.padding(Theme.Spacing.xs)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: width)
            .frame(idealHeight: rowsHeight + Theme.Spacing.sm, maxHeight: tallest)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(DropdownStyle.panel)
            .preferredColorScheme(.dark)
        } else {
            VStack(spacing: 0) {
                header
                ScrollView {
                    rows
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.bottom, Theme.Spacing.md)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .presentationDetents([.height(min(max(headerHeight + rowsHeight, 120), tallest))])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Theme.Radius.composer)
            .presentationBackground(DropdownStyle.panel)
            .preferredColorScheme(.dark)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) { content() }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowsHeight = $0 + Theme.Spacing.md }
    }

    /// The title under the grabber, in the room the grabber needs anyway.
    private var header: some View {
        Group {
            if let title {
                Text(title)
                    .font(Theme.TextStyle.strong)
                    .foregroundStyle(Theme.paper)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.top, Theme.Spacing.xxl)
                    .padding(.bottom, Theme.Spacing.sm)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Color.clear.frame(height: Theme.Spacing.xl)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
    }
}

/// A small grey header over a group of rows.
struct DropdownHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Theme.TextStyle.label)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A thin line between groups.
struct DropdownDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
    }
}

/// One choice: an optional symbol or agent logo, a title, an optional description and trailing text. The chosen row has
/// a faint fill and a check; a disabled row is dimmed and says why under its title. Rows are at least 48 pt tall, so a
/// thumb hits them.
struct DropdownRow: View {
    var symbol: String? = nil
    var agent: String? = nil
    let title: String
    var detail: String? = nil
    var trailing: String? = nil
    var chosen = false
    var tint: Color? = nil
    var disabledReason: String? = nil
    /// Runs once the panel is gone, for a choice that opens something of its own (a picker, an importer).
    var afterClosing = false
    let action: () -> Void
    @Environment(\.closeDropdown) private var close

    var body: some View {
        Button {
            guard disabledReason == nil else { return }
            Haptics.tap()
            if afterClosing {
                close(afterwards: action)
            } else {
                action()
                close()
            }
        } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                if let agent {
                    AgentLogo(agent: agent, size: 20)
                } else if let symbol {
                    Image(icon: symbol)
                        .font(Theme.font(15, .medium))
                        .foregroundStyle(tint ?? Theme.textSecondary)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(verbatim: title)
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(tint ?? Theme.paper)
                        .lineLimit(2)
                    if let note = disabledReason ?? detail, !note.isEmpty {
                        Text(verbatim: note)
                            .font(Theme.TextStyle.detail)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Spacing.sm)
                if let trailing {
                    Text(verbatim: trailing).font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                if chosen {
                    Image(icon: "checkmark").font(Theme.font(13, .semibold)).foregroundStyle(Theme.paper)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DropdownRowPress(chosen: chosen))
        .opacity(disabledReason == nil ? 1 : 0.64)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A row lit while a finger is on it (the Mac lights it under the pointer), the chosen one faintly filled.
private struct DropdownRowPress: ButtonStyle {
    let chosen: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .roundedBackground(configuration.isPressed ? DropdownStyle.pressed : (chosen ? DropdownStyle.chosen : .clear),
                               radius: Theme.Radius.card)
            .animation(Theme.hover, value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

/// The big choices on top of a dropdown (the chat composer's "+": photo library, camera, file) as tinted tiles in a
/// grid of three, as the Mac's `DropdownTileGrid`.
struct DropdownTileGrid<Content: View>: View {
    var columns = 3
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.sm), count: columns),
                  spacing: Theme.Spacing.sm) {
            content()
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }
}

/// One big choice in a `DropdownTileGrid`: its symbol in a tinted tile, the title under it. What it opens shows once the
/// panel is gone.
struct DropdownTile: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void
    @Environment(\.closeDropdown) private var close

    var body: some View {
        Button {
            Haptics.tap()
            close(afterwards: action)
        } label: {
            VStack(spacing: Theme.Spacing.sm) {
                Image(icon: symbol)
                    .font(Theme.font(20, .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .roundedBackground(tint.opacity(0.16), radius: Theme.Radius.sheet)
                Text(verbatim: title)
                    .font(Theme.TextStyle.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(DropdownRowPress(chosen: false))
        .accessibilityLabel(Text(verbatim: title))
    }
}
