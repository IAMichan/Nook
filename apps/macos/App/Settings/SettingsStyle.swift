import SwiftUI
import AppKit

// MARK: - Visual language of Settings
//
// One look everywhere: quiet graphite tiles with a light symbol, soft status pills, and numbered steps for anything that
// needs to be set up. Everything comes from the Nook palette (near-black, soft white, a little mint, amber and coral for
// state), so the settings feel like the same app as the notch.

extension SettingsSection {
    /// Filled symbol on the sidebar tile.
    var tileSymbol: String {
        switch self {
        case .start: return "house.fill"
        case .general: return "gearshape.fill"
        case .notch: return "macbook"
        case .appearance: return "paintpalette.fill"
        case .shortcuts: return "command"
        case .notifications: return "bell.fill"
        case .sound: return "speaker.wave.2.fill"
        case .brain: return "brain"
        case .assistant: return "sparkles"
        case .memory: return "books.vertical.fill"
        case .instructions: return "text.badge.checkmark"
        case .autocomplete: return "keyboard.fill"
        case .dictation: return "waveform"
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .connections: return "person.crop.circle.badge.checkmark"
        case .iphone: return "iphone"
        case .agents: return "terminal.fill"
        case .sessions: return "rectangle.stack.fill"
        case .machines: return "server.rack"
        case .automation: return "clock.arrow.2.circlepath"
        case .pullRequests: return "arrow.triangle.branch"
        case .usage: return "chart.bar.fill"
        case .privacy: return "hand.raised.fill"
        case .worktrees: return "folder.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .about: return "info.circle.fill"
        case .notificationApps: return "app.badge.fill"
        case .autocompleteApps: return "square.grid.2x2.fill"
        case .autocompleteStyle: return "textformat"
        case .autocompletePlayground: return "character.cursor.ibeam"
        case .autocompleteStats: return "chart.line.uptrend.xyaxis"
        case .archive: return "archivebox.fill"
        case .projects: return "folder.badge.gearshape"
        case .openIn: return "arrow.up.forward.app.fill"
        case .permissions: return "checkmark.shield.fill"
        case .onDevice: return "lock.laptopcomputer"
        case .activityLog: return "list.bullet.rectangle.fill"
        }
    }

    /// The line symbol in front of the page's name in the sidebar: one quiet stroke icon per page, so the
    /// column reads as a list of words rather than a row of tiles.
    var sidebarSymbol: String {
        switch self {
        case .start: return "house"
        case .general: return "gearshape"
        case .notch: return "macbook"
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .notifications: return "bell"
        case .sound: return "speaker.wave.2"
        case .dictation: return "mic"
        case .brain: return "brain"
        case .assistant: return "sparkles"
        case .memory: return "books.vertical"
        case .instructions: return "text.badge.checkmark"
        case .autocomplete: return "text.cursor"
        case .agents: return "terminal"
        case .sessions: return "bubble.left.and.text.bubble.right"
        case .automation: return "calendar.badge.clock"
        case .usage: return "chart.bar"
        case .worktrees: return "folder"
        case .pullRequests: return "arrow.triangle.branch"
        case .chats: return "bubble.left.and.bubble.right"
        case .connections: return "person.crop.circle.badge.checkmark"
        case .iphone: return "iphone"
        case .machines: return "server.rack"
        case .privacy: return "hand.raised"
        case .maintenance: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        case .notificationApps: return "app.badge"
        case .autocompleteApps: return "square.grid.2x2"
        case .autocompleteStyle: return "textformat"
        case .autocompletePlayground: return "character.cursor.ibeam"
        case .autocompleteStats: return "chart.line.uptrend.xyaxis"
        case .archive: return "archivebox"
        case .projects: return "folder.badge.gearshape"
        case .openIn: return "arrow.up.forward.app"
        case .permissions: return "checkmark.shield"
        case .onDevice: return "lock.laptopcomputer"
        case .activityLog: return "list.bullet.rectangle"
        }
    }

    /// Top and bottom color of the tile gradient. Tiles themselves are graphite now; a few charts still take the color.
    var tileColors: (Color, Color) {
        switch self {
        case .autocomplete: return (Color(hex: 0x8FE3FF), Color(hex: 0x2FA8D8))
        default: return (NookTheme.smoke, NookTheme.graphite)
        }
    }
}

/// A flat rounded square with a soft symbol: the one icon style of Settings. No gradient and no edge, so a column of
/// them reads as quiet markers rather than a row of buttons.
struct SettingsTile: View {
    let symbol: String
    let colors: (Color, Color)
    var size: CGFloat = 22

    init(symbol: String, colors: (Color, Color), size: CGFloat = 22) {
        self.symbol = symbol
        self.colors = colors
        self.size = size
    }

    init(_ section: SettingsSection, size: CGFloat = 22) {
        self.init(symbol: section.tileSymbol, colors: section.tileColors, size: size)
    }

    /// `colors` is kept for the callers that still pass one: every tile has the same quiet look now.
    var body: some View {
        NookTheme.shape(size * 0.27)
            .fill(NookTheme.smoke)
            .overlay(
                Image(icon: symbol)
                    .font(NookTheme.font(size * 0.48, .medium))
                    .foregroundStyle(NookTheme.textStrong)
            )
            .frame(width: size, height: size)
    }
}

/// A brand icon (favicon) on a soft white tile, the same size and shape as `SettingsTile`, so services and
/// sections line up.
struct ServiceTile: View {
    let domain: String?
    let fallback: String
    var tint: Color = NookTheme.textSecondary
    var size: CGFloat = 28
    /// The source id: a source backed by a Mac app shows that app's own icon instead of a tile.
    var source: String? = nil

    var body: some View {
        if let source, let app = SourceBrand.appIcon(for: source) {
            Image(nsImage: app)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size * 1.15, height: size * 1.15)
                .frame(width: size, height: size)
        } else {
            tile
        }
    }

    private var tile: some View {
        NookTheme.shape(size * 0.27)
            .fill(NookTheme.smoke)
            .overlay(
                SiteIcon(domain: domain, fallback: fallback, tint: tint, size: size * 0.62, source: source)
            )
            .frame(width: size, height: size)
    }
}

/// The state of a connection in plain words and one color.
enum ConnectionHealth: Equatable {
    case working, busy, off, needsYou, broken, notLinked

    var color: Color {
        switch self {
        case .working: return NookTheme.mint
        case .busy: return NookTheme.iris
        case .off: return NookTheme.textSecondary
        case .needsYou: return NookTheme.amber
        case .broken: return NookTheme.coral
        case .notLinked: return NookTheme.textSecondary
        }
    }

    var label: String {
        switch self {
        case .working: return tr("settings2.health.working")
        case .busy: return tr("settings2.health.busy")
        case .off: return tr("settings2.health.off")
        case .needsYou: return tr("settings2.health.needsYou")
        case .broken: return tr("settings2.health.broken")
        case .notLinked: return tr("settings2.health.notLinked")
        }
    }
}

/// Small colored capsule: "Werkt", "Uit", "Er gaat iets mis".
struct HealthPill: View {
    let health: ConnectionHealth
    var text: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if health == .busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(health.color).frame(width: 6, height: 6)
            }
            Text(text ?? health.label)
                .font(NookTheme.TextStyle.label)
                .lineLimit(1)
        }
        .foregroundStyle(health == .off || health == .notLinked ? NookTheme.textSecondary : health.color)
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, 3)
        .background(NookTheme.shape(NookTheme.Radius.chip).fill(health.color.opacity(0.12)))
    }
}

/// A numbered step in a setup sheet: "1  Maak een sleutel".
struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    var done = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
            ZStack {
                Circle().fill(done ? ConnectionHealth.working.color : NookTheme.iris)
                if done {
                    Image(icon: "checkmark").font(NookTheme.font(11, .bold))
                } else {
                    Text("\(number)").font(NookTheme.rounded(12, .bold))
                }
            }
            .foregroundStyle(done ? NookTheme.onPaper : NookTheme.onIris)
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Text(title).font(NookTheme.TextStyle.strong)
                content()
            }
            Spacer(minLength: 0)
        }
    }
}

/// How the last step of a setup flow is doing: Nook checking what the steps before it set up.
enum SetupCheckState: Equatable {
    /// Nothing checked yet (or something earlier changed): the check button shows.
    case idle
    case checking
    /// It works; the line says what Nook found ("Signed in as …", "Reached build-server").
    case passed(String)
    /// It does not work; the line says why in plain words, and the button tries again.
    case failed(String)
}

/// The last step of every setup flow in Settings: Nook checks the link, the key or the address before it is saved, or,
/// where there is nothing to check, says it is ready to add. One look everywhere: the step's number, "Check the
/// connection" (or the caller's title), one line, and the button or the outcome under it.
struct SetupCheckStep: View {
    let number: Int
    var title: String = tr("settings2.step.check")
    /// What will be checked, shown while idle.
    let detail: String
    let state: SetupCheckState
    /// The button that runs the check; nil for a flow with nothing to check (the step then only says it is ready).
    var check: (() -> Void)? = nil
    /// The earlier steps are not done yet: the button stays off.
    var disabled = false

    var body: some View {
        SetupStep(number: number, title: title, done: isPassed) {
            switch state {
            case .idle:
                if let check {
                    StepAction(detail: detail, button: tr("setup.check.button"), prominent: false, disabled: disabled, action: check)
                } else {
                    SettingNote(detail)
                }
            case .checking:
                HStack(spacing: NookTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    SettingNote(tr("setup.check.checking"))
                }
            case .passed(let line):
                SettingNote(line, tone: .success)
            case .failed(let line):
                SettingNote(line, tone: .error)
                if let check {
                    Button(tr("setup.check.retry"), action: check).disabled(disabled)
                }
            }
        }
    }

    private var isPassed: Bool {
        if case .passed = state { return true }
        return false
    }
}

/// A friendly explanation at the top of a page, under the header that already shows the section's icon.
struct IntroCard: View {
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(NookTheme.TextStyle.strong)
                Text(text)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, NookTheme.Spacing.xs)
    }
}

/// One choice in a short list inside a sheet (a machine found on this Mac): its name and a line under it, the chosen one
/// marked, the whole row clickable.
struct SettingsPickRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                    Text(detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(icon: "checkmark").foregroundStyle(NookTheme.mint)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .roundedBackground(NookTheme.rowFill(selected: selected, hovering: hovering, rest: NookTheme.smoke.opacity(0.5)),
                               radius: NookTheme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One part of a sheet ("Account", "In Nook", "What Nook can do with it"): its name above a card with its rows, the same
/// look as a group on a Settings page, so a sheet reads like the page it opened from. Every sheet keeps its parts in one
/// order: first how to link it (numbered `SetupStep`s) or, once linked, the account; then what it does in Nook; then
/// what Nook can do with it; anything rarely needed folded away last.
struct SheetPart<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    /// Inside an opened row (`ConnectionRow`) the row is the card already.
    @Environment(\.sheetEmbedded) private var embedded

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                content()
            }
            .padding(embedded ? 0 : NookTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedBackground(embedded ? Color.clear : NookTheme.surface, radius: NookTheme.Radius.card)
        }
    }
}

/// What one step of linking asks you to do, laid out the same in every connection sheet: what happens (a strong line
/// when the step needs one more word than its title), one line of explanation, and the button under it. Never a button
/// beside a label in a step: that read as a settings row instead of the thing to do next.
struct StepAction: View {
    var title: String? = nil
    let detail: String
    let button: String
    var prominent = true
    var disabled = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if let title {
                Text(title).font(NookTheme.TextStyle.strong)
            }
            Text(detail)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if prominent {
                Button(button, action: action).buttonStyle(.borderedProminent).disabled(disabled)
            } else {
                Button(button, action: action).disabled(disabled)
            }
        }
    }
}

/// A coding agent by name, always with its logo: in a picker, a button, a list or a menu. Wherever Settings names an
/// agent it uses this, so the logos are never there in one place and missing in the next.
struct AgentName: View {
    let kind: AgentKind
    var name: String? = nil

    init(_ kind: AgentKind, name: String? = nil) {
        self.kind = kind
        self.name = name
    }

    var body: some View {
        Label {
            Text(name ?? kind.name)
        } icon: {
            LogoImage.agent(kind)
        }
    }
}

/// Sheet chrome shared by every sheet Settings opens: the icon, title and one line on top (with the state of a linked
/// connection beside them), the content, and the buttons at the bottom. Its buttons follow one rule: a sheet where the
/// steps do the work has one button, Done; a sheet you fill in has Cancel and its one step (Return), both on the right;
/// disconnecting or removing sits on the left.
struct SetupSheet<Icon: View, Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    /// Wider for a sheet that shows a file or a diff; every other sheet keeps the one width.
    var width: CGFloat = 520
    /// How a linked connection is doing, shown as a pill beside the title; nil while it is not linked.
    var status: ConnectionHealth? = nil
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @Environment(\.dismiss) private var dismiss
    /// Shown inside an opened row of a list instead of in its own window: only the content, no header or buttons.
    @Environment(\.sheetEmbedded) private var embedded

    var body: some View {
        if embedded {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            window
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.lg) {
                icon()
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(title).font(NookTheme.TextStyle.heading)
                    Text(subtitle)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let status { HealthPill(health: status) }
            }
            .padding(NookTheme.Spacing.xxl)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                    content()
                }
                .padding(NookTheme.Spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                footer()
            }
            .padding(NookTheme.Spacing.xl)
        }
        .frame(width: width)
        .frame(minHeight: 280, idealHeight: 520, maxHeight: 680)
        // Escape closes the sheet.
        .onExitCommand { dismiss() }
    }
}
