import SwiftUI

/// The setting a search led to: the page scrolls it into the middle and it lights up for a
/// moment. Rows built from `SettingToggle`, `SettingLabel` and `SettingsSectionTitle` mark themselves with
/// `settingsAnchor`; a search for anything else still opens the right page.
@MainActor
final class SettingsHighlight: ObservableObject {
    static let shared = SettingsHighlight()
    /// The text key of the setting to show; cleared once it has been shown.
    @Published var key: String?

    /// The on-screen name of that setting, in the current language.
    var title: String? { key.map { tr($0) } }

    static func anchor(_ title: String) -> String { "setting:" + title }
}

extension View {
    /// Marks a row as the setting called `title`, so a search for it scrolls here and lights it.
    func settingsAnchor(_ title: String) -> some View {
        modifier(SettingsAnchor(title: title))
    }

    /// Scrolls the page to the setting a search led to, once the page is laid out.
    func settingsHighlightScroll(_ proxy: ScrollViewProxy) -> some View {
        modifier(SettingsHighlightScroll(proxy: proxy))
    }
}

private struct SettingsAnchor: ViewModifier {
    let title: String
    @ObservedObject private var highlight = SettingsHighlight.shared
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // A wash just around the row's own text, so lighting it never moves anything.
            .background(NookTheme.shape(NookTheme.Radius.chip)
                .fill(NookTheme.iris.opacity(lit ? 0.22 : 0))
                .padding(.horizontal, -NookTheme.Spacing.sm)
                .padding(.vertical, -NookTheme.Spacing.xs))
            .id(SettingsHighlight.anchor(title))
            .onAppear(perform: light)
            .onChange(of: highlight.key) { _, _ in light() }
    }

    private func light() {
        guard highlight.title == title else { return }
        withAnimation(reduceMotion ? nil : NookTheme.reveal) { lit = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(reduceMotion ? nil : NookTheme.reveal) { lit = false }
            if highlight.title == title { highlight.key = nil }
        }
    }
}

private struct SettingsHighlightScroll: ViewModifier {
    let proxy: ScrollViewProxy
    @ObservedObject private var highlight = SettingsHighlight.shared

    func body(content: Content) -> some View {
        content
            .onAppear(perform: scroll)
            .onChange(of: highlight.key) { _, _ in scroll() }
    }

    private func scroll() {
        guard let title = highlight.title else { return }
        // After the page is laid out: a Form builds its rows a moment after it appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(NookTheme.scroll) { proxy.scrollTo(SettingsHighlight.anchor(title), anchor: .center) }
        }
    }
}

/// A setting's name from its text key, marked so a search for it scrolls here and lights it: the label of a switch,
/// picker or row, or a section's header.
struct SettingText: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(tr(key)).settingsAnchor(tr(key))
    }
}

/// A group of rarely needed settings, folded away: the whole group is one row with a chevron, its name,
/// and on the right a summary of what is inside (the current choice, a count), so you know what you would find before
/// you open it. A search for a setting inside (`keys`) opens it before the page scrolls there. Use it for a whole group
/// of a page, never for one row inside another group; a row that hides a single step says that step instead.
struct SettingsFold<Content: View>: View {
    let title: String
    var summary: String? = nil
    /// The text keys of the settings inside, so a search for one of them opens the fold.
    var keys: [String] = []
    @ViewBuilder var content: () -> Content
    @ObservedObject private var highlight = SettingsHighlight.shared
    @State private var open = false

    init(_ title: String, summary: String? = nil, keys: [String] = [], @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.summary = summary
        self.keys = keys
        self.content = content
    }

    var body: some View {
        Section {
            Button {
                withAnimation(NookTheme.reveal) { open.toggle() }
            } label: {
                SettingsFoldHeader(open: open, summary: summary) { Text(title) }
            }
            .buttonStyle(.nookPlain)
            .settingsAnchor(title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? tr("settings.fold.open") : (summary ?? tr("settings.fold.closed")))
            if open {
                content()
            }
        }
        .onAppear(perform: openForSearch)
        .onChange(of: highlight.key) { _, _ in openForSearch() }
    }

    private func openForSearch() {
        guard let key = highlight.key, keys.contains(key) || highlight.title == title else { return }
        open = true
    }
}

/// The header line of every fold in Settings: a chevron, the name, and on the right a summary while closed. Shared by
/// `SettingsFold` and `SettingsDisclosureStyle`, so a fold of a whole group and a fold inside a row look the same.
struct SettingsFoldHeader<Label: View>: View {
    let open: Bool
    var summary: String? = nil
    @ViewBuilder var label: () -> Label

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            DisclosureChevron(open: open, size: 10, weight: .semibold)
                .frame(width: 12)
            label()
                .foregroundStyle(NookTheme.paper)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let summary, !open {
                Text(summary)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, NookTheme.Spacing.lg)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Every `DisclosureGroup` on a Settings page or in a sheet draws as a `SettingsFold`: the same chevron, name and
/// animation, the whole line clickable, its content under it. Set by `SettingsFormStyle` and `SheetPart`, so a fold
/// inside a row never falls back to the system disclosure triangle.
struct SettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Button {
                withAnimation(NookTheme.reveal) { configuration.isExpanded.toggle() }
            } label: {
                SettingsFoldHeader(open: configuration.isExpanded) { configuration.label }
            }
            .buttonStyle(.nookPlain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(configuration.isExpanded ? tr("settings.fold.open") : tr("settings.fold.closed"))
            if configuration.isExpanded {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    configuration.content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
