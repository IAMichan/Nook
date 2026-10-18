import SwiftUI

/// The box you write to an agent in. Starting a session and answering one look and work the same: the text on top,
/// underneath the choices for the turn (agent, mode, permissions…) passed in as `controls`, and the send button on
/// the right, which turns into a stop button while the agent works.
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

    @FocusState private var ownFocus: Bool

    /// The same composer that, while busy, queues what you type (Return or the queue button) for after the turn.
    func queueing(_ action: (() -> Void)?, label: String = tr("compose.queue"), symbol: String = "text.append") -> Self {
        var copy = self
        copy.queueAction = action
        copy.queueLabel = label
        copy.queueSymbol = symbol
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
    static var accent: Color { Color(hex: 0x3D58D6) }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var enabled: Bool { canSend && !sending && !isEmpty }

    var body: some View {
        let focused = focus ?? $ownFocus
        VStack(alignment: .leading, spacing: 12) {
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.font(14))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(lines)
                .focused(focused)
                .onSubmit {
                    if busy, let queueAction, !isEmpty { queueAction() } else if enabled { onSend() }
                }
                .onChange(of: text) { _, new in NookPresence.shared.typed(count: new.count) }
                .frame(minHeight: minHeight, alignment: .topLeading)
            HStack(spacing: 6) {
                controls()
                Spacer(minLength: 8)
                if let trailingAccessory { trailingAccessory }
                if busy, let onStop {
                    if let queueAction, !isEmpty {
                        roundButton(symbol: queueSymbol, label: queueLabel, active: true, action: queueAction)
                    }
                    roundButton(symbol: "stop.fill", label: tr("button.stop"), active: true, action: onStop)
                } else {
                    roundButton(symbol: "arrow.up", label: sendLabel ?? tr("button.send"), active: enabled, action: onSend)
                        .disabled(!enabled)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Self.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focused.wrappedValue ? NookTheme.line2 : Color(hex: 0x222226), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: focused.wrappedValue)
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
            .foregroundStyle(active ? Color.white : NookTheme.textTertiary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(active ? Self.accent : NookTheme.smoke))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
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
    var tint: Color? = nil
    var showsChevron = true
    @State private var hovering = false

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
            Text(text).lineLimit(1)
            if showsChevron {
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
