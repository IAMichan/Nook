import SwiftUI

/// The look of every Settings page: each `Section` is its title, then one bordered card with its rows under each other,
/// a line between two rows, a row's name and explanation on the left and its control on the right. The footer sits
/// under the card. A page stays a plain `Form` of `Section`s; this style is the only place that draws the groups.
struct SettingsFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            // Not lazy: a search scrolls to a setting anywhere on the page, so every row must be there.
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxxl) {
                ForEach(sections: configuration.content) { section in
                    SettingsFormSection(section: section)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.xxl)
            .padding(.vertical, NookTheme.Spacing.xxl)
        }
        .toggleStyle(SettingsRowToggleStyle())
        .labeledContentStyle(SettingsRowLabeledStyle())
    }
}

extension ContainerValues {
    /// A section drawn without its card (a preview or a row of tiles that brings its own surface).
    @Entry var settingsBareSection = false
}

extension View {
    /// Draws this `Section` of a Settings page without its card, for content that brings its own surface.
    func settingsBareSection() -> some View {
        containerValue(\.settingsBareSection, true)
    }
}

/// One group of a page: its title, the card with its rows, and its footer.
private struct SettingsFormSection: View {
    let section: SectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if !section.header.isEmpty {
                section.header
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                    .padding(.leading, NookTheme.Spacing.xxs)
                    .accessibilityAddTraits(.isHeader)
            }
            if section.containerValues.settingsBareSection {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) { section.content }
            } else {
                card
            }
            if !section.footer.isEmpty {
                section.footer
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.horizontal, NookTheme.Spacing.xxs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: section.content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { NookDivider() }
                    rows[index]
                        .padding(.horizontal, NookTheme.Spacing.scaled(NookTheme.Spacing.xl))
                        .padding(.vertical, NookTheme.Spacing.scaled(NookTheme.Spacing.lg))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.panel)
        .roundedClip(NookTheme.Radius.panel)
        .roundedStrokeBorder(NookTheme.separator, radius: NookTheme.Radius.panel)
    }
}

/// A switch on a Settings row: its label (a name, or a name with its explanation under it) on the left, the switch on
/// the right. A toggle that asks for another style (a checkbox) keeps it.
struct SettingsRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: NookTheme.Spacing.xl) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .compactSwitch()
        }
        // One element for VoiceOver: the name, its explanation and the switch's state together.
        .accessibilityElement(children: .combine)
    }
}

/// A `LabeledContent` on a Settings row: the name on the left, the value or control on the right.
struct SettingsRowLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: NookTheme.Spacing.xl) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
                .foregroundStyle(NookTheme.textSecondary)
                .multilineTextAlignment(.trailing)
                .settingsMenu()
        }
    }
}

/// The size of the controls on a Settings row: one height for fields and menus, and one width a field on the right of
/// a row takes, so a page's controls line up as one column instead of each stretching to what is left of its row.
enum SettingsControl {
    /// A field's and a menu's height: a little taller than the system's, so a row reads calm and easy to hit.
    static let height: CGFloat = 28
    /// The width of a field on the right of a row (a name, a prefix, an address).
    static let fieldWidth: CGFloat = 220
}

extension View {
    /// A text or secure field on a Settings page or sheet: Nook's field fill and hairline at `SettingsControl.height`,
    /// its text from the leading edge. Use it instead of `.settingsField()`.
    func settingsField() -> some View {
        modifier(SettingsFieldStyle())
    }

    /// A menu on a Settings row at `SettingsControl.height`, sized to its choices.
    func settingsMenu() -> some View {
        controlSize(.large)
    }
}

private struct SettingsFieldStyle: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shape = NookTheme.shape(NookTheme.Radius.control)
        content
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.paper)
            .focused($focused)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .frame(minHeight: SettingsControl.height)
            .background(shape.fill(NookTheme.field))
            .overlay(shape.strokeBorder(focused ? NookTheme.line2 : NookTheme.fieldStroke, lineWidth: 1))
            .contentShape(shape)
    }
}
