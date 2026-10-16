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

    @FocusState private var ownFocus: Bool

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
                .onSubmit { if enabled { onSend() } }
                .frame(minHeight: minHeight, alignment: .topLeading)
            HStack(spacing: 6) {
                controls()
                Spacer(minLength: 8)
                if busy, let onStop {
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
    let text: String
    var tint: Color? = nil
    var showsChevron = true
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let agent {
                AgentMark(agent: agent, account: account, size: 15, ring: SessionComposer<EmptyView>.surface)
                    .padding(.trailing, account == nil ? 0 : 3)
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
