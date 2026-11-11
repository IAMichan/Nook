import SwiftUI

// The small building blocks every tab and page repeats: a search field, a list's title row, a count, a section label,
// a divider, a notice bar under the tabs, and the quiet card that groups rows. Each one looks and behaves the same
// wherever it is used, so a change here changes every place at once. Never rebuild one of these inline.

/// The one search field: a magnifying glass, the text, and a clear button once there is something to clear. Escape
/// clears it too. `panel` sits in a list in the notch or window (a soft filled field), `ghost` reads as one more row of
/// the sidebar (no fill until the pointer is on it), `inline` sits in a Settings form row (the form draws the row),
/// `large` heads a command palette.
struct NookSearchField: View {
    enum Style { case panel, ghost, inline, large }

    let prompt: String
    @Binding var text: String
    var style: Style = .panel
    /// Focus from the view that owns the field, e.g. to focus it with ⌘F or when a palette opens.
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: (() -> Void)? = nil
    /// Escape after the text is cleared (e.g. to close a palette or drop focus).
    var onEscape: (() -> Void)? = nil
    @State private var hovering = false

    private var glyphSize: CGFloat {
        switch style {
        case .large, .ghost: return 13
        case .panel, .inline: return 11
        }
    }

    var body: some View {
        HStack(spacing: style == .ghost ? NookTheme.Spacing.md : NookTheme.Spacing.sm) {
            Image(icon: "magnifyingglass")
                .font(NookTheme.font(glyphSize, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                ToolbarIconButton("xmark.circle.fill", tr("button.clear"), height: 20, width: 20) { text = "" }
            }
        }
        .padding(.horizontal, style == .inline ? 0 : NookTheme.Spacing.md)
        .frame(height: height)
        .background {
            if style == .panel {
                NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.field)
            } else if style == .ghost, hovering {
                NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.rowHover)
            }
        }
        .onHover { if style == .ghost { hovering = $0 } }
    }

    private var height: CGFloat? {
        switch style {
        case .panel: return 30
        case .ghost: return 32
        case .inline: return nil
        case .large: return 44
        }
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField("", text: $text, prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary))
            .textFieldStyle(.plain)
            // A grouped Settings form lines its fields up to the right; a search reads from the left, as everywhere else.
            .multilineTextAlignment(.leading)
            .labelsHidden()
            .font(style == .large ? NookTheme.font(14) : NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.paper)
            .onSubmit { onSubmit?() }
            .onExitCommand {
                if text.isEmpty { onEscape?() } else { text = "" }
            }
            .accessibilityLabel(prompt)
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}

extension View {
    /// Puts the keyboard in a field the moment it opens (a palette, ⌘K search), so you can type straight away. A field
    /// that appears with a transition is not in the window yet during `onAppear`, and the panel may take the keyboard
    /// only after it opened, so the focus is asked again on the next turn of the run loop, a moment later, and whenever
    /// the window becomes key.
    func focusOnAppear(_ focus: FocusState<Bool>.Binding) -> some View {
        onAppear {
            focus.wrappedValue = true
            DispatchQueue.main.async { focus.wrappedValue = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focus.wrappedValue = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            focus.wrappedValue = true
        }
    }

    /// The same for a composer that is on screen next to other fields: it asks for the keyboard now, on the next turn,
    /// after a moment and when the window becomes key, but never takes it from another text that is being edited.
    /// `enabled` false (a card that should not take the keyboard) does nothing.
    func composerFocusOnAppear(_ focus: FocusState<Bool>.Binding, enabled: Bool = true) -> some View {
        func ask() {
            guard enabled, !focus.wrappedValue else { return }
            // An editing text view in the key window is another field with the keyboard (this one is not focused yet).
            if NSApp.keyWindow?.firstResponder is NSTextView { return }
            focus.wrappedValue = true
        }
        return onAppear {
            ask()
            DispatchQueue.main.async { ask() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ask() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in ask() }
        // A side panel that closed with the keyboard dropped, and nothing to give it back to (`SideFocusReturn`).
        .onReceive(NotificationCenter.default.publisher(for: .nookComposerFocusRequest)) { _ in ask() }
    }
}

/// A button drawn as a `NookSearchField` that opens a search instead of being one (the Chats tab's rail of icons opens
/// Search everything with it): the same field, glyph and inset, the prompt, and the shortcut as a `NookKeyHint`.
/// `compact` is only the glyph, for a rail of icons.
struct NookSearchLauncher: View {
    let prompt: String
    var shortcut: String? = nil
    var help: String? = nil
    var compact = false
    var height: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = NookTheme.shape(NookTheme.Radius.control)
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: "magnifyingglass")
                    .font(NookTheme.font(11, .medium))
                    .accessibilityHidden(true)
                if !compact {
                    Text(prompt)
                        .font(NookTheme.TextStyle.body)
                        .lineLimit(1)
                    Spacer(minLength: NookTheme.Spacing.xs)
                    if let shortcut { NookKeyHint(text: shortcut) }
                }
            }
            .foregroundStyle(hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
            .padding(.horizontal, compact ? 0 : NookTheme.Spacing.md)
            .frame(maxWidth: compact ? height + NookTheme.Spacing.sm : .infinity, minHeight: height, maxHeight: height)
            .background(shape.fill(NookTheme.field))
            .overlay(shape.strokeBorder(hovering ? NookTheme.line2 : NookTheme.fieldStroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(help ?? prompt)
        .accessibilityLabel(help ?? prompt)
    }
}

/// A keyboard shortcut as a small key: the keys in quiet text on a faint cap.
struct NookKeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NookTheme.font(10.5, .medium))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .frame(height: 18)
            .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.chip)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The title row on top of a tab's list (Nook, Agents, Chats, Pull requests): the name, what waits, and the list's own
/// actions on the right. Every list starts with this same row, so the lists line up when you switch tabs.
struct PanelListHeader<Trailing: View>: View {
    let title: String
    var count: Int = 0
    /// What the list holds, said in the main window's sidebar, where the tab's own name is already a row above it
    /// ("Sessions" under Agents). There the title is a quiet section label.
    var sidebarTitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.inPanelSidebar) private var inSidebar

    init(_ title: String, count: Int = 0, sidebarTitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.count = count
        self.sidebarTitle = sidebarTitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(inSidebar ? sidebarTitle ?? title : title)
                .font(inSidebar ? NookTheme.TextStyle.label : NookTheme.TextStyle.title)
                .foregroundStyle(inSidebar ? NookTheme.textTertiary : NookTheme.paper)
                .lineLimit(1)
            NookCountBadge(count: count)
            Spacer(minLength: NookTheme.Spacing.xs)
            HStack(spacing: NookTheme.Spacing.xxs) { trailing() }
        }
        .frame(height: 30)
        // In the sidebar the label lines up with the marks of the tab rows above it.
        .padding(.leading, inSidebar ? NookTheme.Spacing.md : NookTheme.Spacing.lg)
    }
}

extension PanelListHeader where Trailing == EmptyView {
    init(_ title: String, count: Int = 0, sidebarTitle: String? = nil) {
        self.init(title, count: count, sidebarTitle: sidebarTitle) { EmptyView() }
    }
}

/// "New" in a list's title row (a new Nook, a new session): lit while the new one is what is open.
struct PanelNewButton: View {
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(icon: "square.and.pencil")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(active || hovering ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 28, height: 28)
                .roundedBackground(active || hovering ? NookTheme.smoke : Color.clear, radius: NookTheme.Radius.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A notice that comes in while the panel is open (a permission request, an agent's question, a short note): the
/// shared `NookNotice` in one quiet bar under the tabs, with its actions on the right. `tone` tints the mark and the
/// edge for something risky. With `countdown` the notice closes by itself and ends in the OK with its ring; a request
/// that waits for you has none.
struct PanelNoticeBar<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var tone: Color? = nil
    var help: String? = nil
    /// The notice's own actions, in the dark bar before the OK (a note that closes by itself).
    var actions: [NookNoticeAction] = []
    var countdown: TimeInterval? = nil
    var paused: Bool = false
    var onOK: () -> Void = {}
    /// Floats in the panel's top-right corner in the toast's bubble (`toastBubble`), as narrow as a toast and on top of
    /// them, instead of a bar under the tabs: a request or a note that comes in while you work elsewhere in the panel.
    var floating: Bool = false
    /// What a request that waits for you asks with (`NookNoticeActions`: Allow and Deny).
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let notice = NookNotice(title: title, detail: detail, symbol: symbol, tone: tone ?? NookTheme.textSecondary,
                                actions: actions, countdown: countdown, paused: paused, wraps: floating, onOK: onOK,
                                trailing: trailing)
            .help(help ?? title)
        if floating {
            notice
                .toastBubble(tone: tone ?? NookTheme.textSecondary, maxWidth: NookToastView.maxWidth)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            notice
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.md)
                .cardBackground(NookTheme.surface, stroke: (tone ?? NookTheme.line2).opacity(tone == nil ? 1 : 0.35),
                                radius: NookTheme.Radius.panel)
                .padding(.top, NookTheme.Spacing.md)
                .transition(.opacity.combined(with: .offset(y: -4)))
        }
    }
}

extension NookFilterChip {
    /// A chip whose mark is the state of a workflow's newest run, shown only while it runs or when it failed.
    init(title: String, count: Int? = nil, selected: Bool, mark: (outcome: PullRequestCheck.Outcome, running: Bool)?,
         action: @escaping () -> Void) {
        let glyph = mark.flatMap { mark in
            mark.outcome == .failing || mark.outcome == .pending
                ? AnyView(CheckOutcomeGlyph(outcome: mark.outcome, size: 10, running: mark.running)) : nil
        }
        self.init(title: title, count: count, selected: selected, mark: glyph, action: action)
    }
}
