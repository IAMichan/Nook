import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The box you write to an agent or to Nook in. Starting a session, answering one and chatting look and work the same:
/// the text on top, underneath the choices for the turn (agent, mode, permissions… or model and sources) passed in as
/// `controls`, and the send button on the right in Nook's own color, which turns into a stop button while work runs.
struct SessionComposer<Controls: View>: View {
    @Binding var text: String
    let prompt: String
    /// Room for the text before you type: a few lines when starting a session, one line when answering.
    var minHeight: CGFloat = 20
    var lines: ClosedRange<Int> = 1...6
    /// Anything besides an empty text that keeps the message from going out (no folder chosen, agent busy…).
    var canSend = true
    var sending = false
    /// The agent is working: the button stops it instead of sending (when `onStop` is given).
    var busy = false
    var onStop: (() -> Void)? = nil
    var sendLabel: String? = nil
    var focus: FocusState<Bool>.Binding? = nil
    let onSend: () -> Void
    @ViewBuilder var controls: () -> Controls

    /// An extra round button next to send (the microphone), kept on the right instead of among the choices.
    private var trailingAccessory: AnyView?
    /// While busy: puts the text in line for after the current turn (or steers the turn) instead of sending it.
    private var queueAction: (() -> Void)?
    private var queueLabel = ""
    private var queueSymbol = "text.append"
    /// Cmd+Return while busy: the other way to deliver the text (steer instead of queue, or the reverse).
    private var flipAction: (() -> Void)?
    /// The list under the text, history and references (see `ComposerRich`); nil keeps the plain box.
    private var extras: (model: ComposerModel, config: ComposerConfig)?
    /// The composer's own color: the send button, the focus ring and a trace in the surface.
    private var tint: Color = NookTheme.iris

    /// Pictures added by dragging or pasting. Optional: a composer without it does not take pictures.
    private var imagesBinding: Binding<[ImageAttachment]>?
    /// Agents read pictures from disk: on send their paths go below the text. Without it the caller sends the pictures itself.
    private var imagesAsPaths = true
    /// What happens to another file that is dropped (default: its path goes into the text, which agents read).
    private var fileDropped: ((URL) -> Void)?

    @FocusState private var ownFocus: Bool
    @State private var dropTargeted = false
    @State private var pasteMonitor = PasteMonitor()

    /// The same composer that, while busy, queues what you type (Return or the queue button) for after the turn.
    func queueing(_ action: (() -> Void)?, alternate: (() -> Void)? = nil, label: String = tr("compose.queue"),
                  symbol: String = "text.append") -> Self {
        var copy = self
        copy.queueAction = action
        copy.flipAction = alternate
        copy.queueLabel = label
        copy.queueSymbol = symbol
        return copy
    }

    /// The same composer with rich workspace behaviour: `/`, `@` and `#` lists, ArrowUp for earlier messages, references, and the
    /// composer's own tint. The model belongs to the call site, which sends through `model.outgoing(_:)`.
    func rich(_ model: ComposerModel, _ config: ComposerConfig) -> Self {
        var copy = self
        copy.extras = (model, config)
        copy.tint = config.tint
        return copy
    }

    /// The same composer that takes pictures (drag, drop and paste) and shows them above the text.
    func images(_ images: Binding<[ImageAttachment]>, asPaths: Bool = true, onFile: ((URL) -> Void)? = nil) -> Self {
        var copy = self
        copy.imagesBinding = images
        copy.imagesAsPaths = asPaths
        copy.fileDropped = onFile
        return copy
    }

    /// The same composer with a small view placed right before the send button.
    func trailing<Accessory: View>(@ViewBuilder _ accessory: () -> Accessory) -> Self {
        var copy = self
        copy.trailingAccessory = AnyView(accessory())
        return copy
    }

    init(
        text: Binding<String>,
        prompt: String,
        minHeight: CGFloat = 20,
        lines: ClosedRange<Int> = 1...6,
        canSend: Bool = true,
        sending: Bool = false,
        busy: Bool = false,
        onStop: (() -> Void)? = nil,
        sendLabel: String? = nil,
        focus: FocusState<Bool>.Binding? = nil,
        onSend: @escaping () -> Void,
        @ViewBuilder controls: @escaping () -> Controls
    ) {
        self._text = text
        self.prompt = prompt
        self.minHeight = minHeight
        self.lines = lines
        self.canSend = canSend
        self.sending = sending
        self.busy = busy
        self.onStop = onStop
        self.sendLabel = sendLabel
        self.focus = focus
        self.onSend = onSend
        self.controls = controls
    }

    /// Convenience initializer where `focus` precedes `busy`, preventing argument-order compiler errors.
    init(
        text: Binding<String>,
        prompt: String,
        minHeight: CGFloat = 20,
        lines: ClosedRange<Int> = 1...6,
        canSend: Bool = true,
        sending: Bool = false,
        focus: FocusState<Bool>.Binding?,
        busy: Bool = false,
        onStop: (() -> Void)? = nil,
        sendLabel: String? = nil,
        onSend: @escaping () -> Void,
        @ViewBuilder controls: @escaping () -> Controls
    ) {
        self._text = text
        self.prompt = prompt
        self.minHeight = minHeight
        self.lines = lines
        self.canSend = canSend
        self.sending = sending
        self.busy = busy
        self.onStop = onStop
        self.sendLabel = sendLabel
        self.focus = focus
        self.onSend = onSend
        self.controls = controls
    }

    static var surface: Color { Color(hex: 0x121214) }

    private var hasImages: Bool { !(imagesBinding?.wrappedValue.isEmpty ?? true) }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasImages }
    private var enabled: Bool { canSend && !sending && !isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let extras, extras.model.isOpen {
                ComposerSuggestionList(model: extras.model, tint: tint) { choose($0) }
            }
            box
        }
    }

    private func assign(_ value: String) {
        if let extras, value != text { extras.model.applying = true }
        text = value
    }

    private func choose(_ suggestion: ComposerSuggestion) {
        guard let extras else { return }
        assign(extras.model.accept(suggestion, in: text, extras.config))
        (focus ?? $ownFocus).wrappedValue = true
    }

    private func textChanged(_ old: String, _ new: String) {
        NookPresence.shared.typed(count: new.count)
        guard let extras else { return }
        if extras.model.applying {
            extras.model.applying = false
            return
        }
        extras.model.history.stopWalking()
        if extras.config.keepsBigPastes, let kept = extras.model.keepPaste(old: old, new: new) {
            assign(kept)
            extras.model.close()
            return
        }
        extras.model.update(for: new, extras.config)
    }

    private func arrow(_ delta: Int) -> KeyPress.Result {
        guard let extras else { return .ignored }
        if extras.model.isOpen {
            extras.model.move(delta)
            return .handled
        }
        if delta < 0 {
            guard ComposerKeys.arrowWalksHistory(text: text, walking: extras.model.history.isWalking),
                  let previous = extras.model.history.previous(current: text) else { return .ignored }
            assign(previous)
            return .handled
        }
        guard extras.model.history.isWalking, let next = extras.model.history.next() else { return .ignored }
        assign(next)
        return .handled
    }

    private func returnKey(_ press: KeyPress) -> KeyPress.Result {
        if let extras, extras.model.isOpen, extras.model.suggestions.indices.contains(extras.model.selection) {
            choose(extras.model.suggestions[extras.model.selection])
            return .handled
        }
        guard press.modifiers.contains(.command) else { return .ignored }
        if busy {
            if !isEmpty, let flipAction { flipAction() }
        } else if enabled {
            onSend()
        }
        return .handled
    }

    /// Cmd+S: set the draft aside, bring one back, or choose from several.
    private func stashKey(_ press: KeyPress) -> KeyPress.Result {
        guard let extras, press.modifiers.contains(.command), let result = extras.model.stashKey(composerText: text) else {
            return press.modifiers.contains(.command) ? .handled : .ignored
        }
        assign(result)
        extras.model.onStashChanged?()
        return .handled
    }

    private func tabKey() -> KeyPress.Result {
        guard let extras, extras.model.isOpen, extras.model.suggestions.indices.contains(extras.model.selection) else { return .ignored }
        choose(extras.model.suggestions[extras.model.selection])
        return .handled
    }

    private func escapeKey() -> KeyPress.Result {
        guard let extras, extras.model.isOpen else { return .ignored }
        extras.model.close()
        return .handled
    }

    // The text field and its keys are built in separate steps: as one chain the compiler cannot type-check it in time.
    private func field(focused: FocusState<Bool>.Binding) -> some View {
        let placeholder: Text = Text(prompt).foregroundStyle(NookTheme.textTertiary)
        return TextField("", text: $text, prompt: placeholder, axis: .vertical)
            .textFieldStyle(.plain)
            .font(NookTheme.font(14))
            .foregroundStyle(NookTheme.paper)
            .lineLimit(lines)
            .focused(focused)
            .onSubmit(submit)
            .onChange(of: text) { old, new in textChanged(old, new) }
    }

    private func withKeys(_ view: some View) -> some View {
        view
            .onKeyPress(.upArrow) { () -> KeyPress.Result in arrow(-1) }
            .onKeyPress(.downArrow) { () -> KeyPress.Result in arrow(1) }
            .onKeyPress(.tab) { () -> KeyPress.Result in tabKey() }
            .onKeyPress(.escape) { () -> KeyPress.Result in escapeKey() }
            // These two need the modifiers, so the overload that passes the KeyPress (it has no default phases).
            .onKeyPress(.return, phases: .down) { (press: KeyPress) -> KeyPress.Result in returnKey(press) }
            .onKeyPress(KeyEquivalent("s"), phases: .down) { (press: KeyPress) -> KeyPress.Result in stashKey(press) }
    }

    private func submit() {
        if busy, let queueAction, !isEmpty { fire(queueAction) } else if enabled { fire(onSend) }
    }

    private var box: some View {
        let focused = focus ?? $ownFocus
        return VStack(alignment: .leading, spacing: 12) {
            if let imagesBinding, !imagesBinding.wrappedValue.isEmpty {
                ImageAttachmentStrip(images: imagesBinding.wrappedValue) { gone in
                    imagesBinding.wrappedValue.removeAll { $0.id == gone.id }
                }
            }
            withKeys(field(focused: focused))
                .frame(minHeight: minHeight, alignment: .topLeading)
            // When the box gets narrow (the chat beside an open app), the choices give up their words step by step,
            // so the row shrinks with the box instead of running out of it while keeping as much text as fits.
            ViewThatFits(in: .horizontal) {
                controlRow.environment(\.composerDensity, .full)
                controlRow.environment(\.composerDensity, .short)
                controlRow.environment(\.composerDensity, .marks)
                controlRow.environment(\.composerDensity, .icons)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Self.surface)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tint.opacity(0.035)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focused.wrappedValue ? tint.opacity(0.5) : Color(hex: 0x222226), lineWidth: 1)
        )
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(NookTheme.iris, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: focused.wrappedValue)
        .onDrop(of: imagesBinding == nil ? [] : [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
            guard let imagesBinding else { return false }
            return ImageAttachment.receive(providers, images: { imagesBinding.wrappedValue += $0 }, file: { url in
                if let fileDropped { fileDropped(url) } else { insertPath(url) }
            })
        }
        .onAppear { startPasteMonitor(focused: focused) }
        .onDisappear { pasteMonitor.stop() }
    }

    /// The choices for the turn, then the extra button and send (or stop) on the right.
    private var controlRow: some View {
        HStack(spacing: 6) {
            controls()
            Spacer(minLength: 8)
            if let trailingAccessory { trailingAccessory }
            if busy, let onStop {
                if let queueAction, !isEmpty {
                    roundButton(symbol: queueSymbol, label: queueLabel, active: true) { fire(queueAction) }
                }
                roundButton(symbol: "stop.fill", label: tr("button.stop"), active: true, action: onStop)
            } else {
                roundButton(symbol: "arrow.up", label: sendLabel ?? tr("button.send"), active: enabled) { fire(onSend) }
                    .disabled(!enabled)
            }
        }
    }

    /// Sends. For agents the pictures first become paths below the text, so the caller's own send sees one text.
    private func fire(_ action: () -> Void) {
        if imagesAsPaths, let imagesBinding, !imagesBinding.wrappedValue.isEmpty {
            text = ImageAttachment.appendingPaths(of: imagesBinding.wrappedValue, to: text)
            imagesBinding.wrappedValue = []
        }
        action()
    }

    private func insertPath(_ url: URL) {
        let path = url.path.contains(" ") ? "\"\(url.path)\"" : url.path
        text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + path + " "
    }

    /// Cmd-V with a picture on the clipboard adds it here; with text it pastes as always.
    private func startPasteMonitor(focused: FocusState<Bool>.Binding) {
        guard let imagesBinding else { return }
        pasteMonitor.start {
            guard focused.wrappedValue else { return false }
            let pictures = ImageAttachment.fromPasteboard()
            guard !pictures.isEmpty else { return false }
            imagesBinding.wrappedValue += pictures
            return true
        }
    }

    private func roundButton(symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(active ? NookTheme.onIris : NookTheme.textTertiary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(active ? tint : NookTheme.smoke))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Watches for Cmd-V while a composer is on screen and lets it claim a paste that holds a picture.
final class PasteMonitor {
    private var monitor: Any?

    func start(handle: @escaping () -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "v" else { return event }
            return handle() ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

/// A quiet choice inside or under the composer: an agent logo, a symbol or a colored dot, and a short text.
struct ComposerPill: View {
    var symbol: String? = nil
    var dot: Color? = nil
    /// Shows this agent's logo (with the account badge) in front of the text.
    var agent: String? = nil
    var account: AccountKind? = nil
    /// Shows this brand's mark in front of the text (a model's maker).
    var brand: BrandLogo? = nil
    let text: String
    /// A shorter text for a narrower composer (the model alone instead of agent, account and model).
    var short: String? = nil
    var tint: Color? = nil
    var showsChevron = true
    @Environment(\.composerDensity) private var density
    @State private var hovering = false

    private var hasMark: Bool { agent != nil || brand != nil }

    /// Only a pill with an icon ever drops its text; one without keeps its words. A logo already says who, so those go
    /// first; a symbol alone says too little, so those keep their words until nothing else fits.
    private var iconOnly: Bool {
        switch density {
        case .full, .short: return false
        case .marks: return hasMark
        case .icons: return hasMark || dot != nil || symbol != nil
        }
    }

    private var shown: String { density == .full ? text : short ?? text }

    var body: some View {
        HStack(spacing: 6) {
            if let agent {
                AgentMark(agent: agent, account: account, size: 15, ring: SessionComposer<EmptyView>.surface)
                    .padding(.trailing, account == nil ? 0 : 3)
            } else if let brand {
                BrandMark(logo: brand, size: 14)
            } else if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            }
            if !iconOnly {
                Text(shown).lineLimit(1)
            }
            if showsChevron && density == .full {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
        }
        .font(NookTheme.font(12.5, .medium))
        .foregroundStyle(tint ?? (hovering ? NookTheme.paper : NookTheme.textSecondary))
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? NookTheme.smoke : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// How much of each choice the composer's row has room for, from everything down to icons only.
enum ComposerDensity {
    /// Every word and the chevrons.
    case full
    /// Short texts (the model alone), no chevrons.
    case short
    /// Pills with a logo show only it; pills with a symbol keep their short text.
    case marks
    /// Only icons.
    case icons
}

private struct ComposerDensityKey: EnvironmentKey {
    static let defaultValue = ComposerDensity.full
}

extension EnvironmentValues {
    /// How much room the composer's row of choices has.
    var composerDensity: ComposerDensity {
        get { self[ComposerDensityKey.self] }
        set { self[ComposerDensityKey.self] = newValue }
    }
}

/// A choice in the composer that is only a symbol (the plus menu): the same size and hover as `ComposerPill`.
struct ComposerIcon: View {
    let symbol: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? NookTheme.smoke : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A thin line between two choices in the composer.
struct ComposerDivider: View {
    var body: some View {
        Rectangle().fill(NookTheme.line2).frame(width: 1, height: 14)
    }
}

extension View {
    /// A menu that looks like its label only: no button chrome, no arrow.
    func composerMenu() -> some View {
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
