import SwiftUI

/// The pill-shaped message field shared by the Nook chat and the agents chat:
/// multi-line text, optional mic, and a send button (or a stop button while busy).
struct NookInputBar: View {
    @Binding var text: String
    let prompt: String
    var focus: FocusState<Bool>.Binding? = nil
    var busy = false
    var onMic: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    let onSend: () -> Void

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            field

            if busy, let onStop {
                NookIconButton(systemName: "stop.fill", label: tr("button.stop"), size: 28, action: onStop)
            } else {
                if let onMic {
                    NookIconButton(systemName: "mic", label: tr("button.talk"), size: 28, action: onMic)
                }
                NookIconButton(systemName: "arrow.up", label: tr("button.send"), filled: canSend, size: 28, action: onSend)
                    .disabled(!canSend)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 42)
        .background(RoundedRectangle(cornerRadius: 21, style: .continuous).fill(NookTheme.field))
        .overlay(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke((focus?.wrappedValue ?? false) ? NookTheme.iris.opacity(0.65) : NookTheme.line2, lineWidth: (focus?.wrappedValue ?? false) ? 1.5 : 1)
        )
        .animation(.easeInOut(duration: 0.18), value: focus?.wrappedValue ?? false)
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField(
            "",
            text: $text,
            prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(NookTheme.font(14))
        .foregroundStyle(NookTheme.paper)
        .lineLimit(1...5)
        .onSubmit(onSend)

        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}
