import SwiftUI
import UIKit

// The phone's own views, built on the parts it shares with the Mac (apps/macos/NotchUI/Shared): each one draws as its
// counterpart in Nook on the Mac, with touch instead of hover. Change the shared part, not a copy of it here.

// MARK: Surfaces

extension View {
    /// What belongs together on one card, card: the surface a step above the screen, its 20 pt corners and a
    /// faint edge. With `tint` (something that waits on you, an error) the edge takes that color.
    func card(padding: CGFloat = Theme.Spacing.xl, tint: Color? = nil) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(Theme.surface, stroke: tint?.opacity(0.32) ?? Theme.line, radius: PhoneRadius.card, style: .continuous)
    }

    /// The dark canvas behind a whole screen, with matching bars.
    func screen() -> some View {
        self
            .background(Theme.canvas.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
    }
}

/// A group's name above its rows ("Needs you", "On MacBook"), section label: small, bold capitals with wide
/// spacing, amber when what it holds waits on you, with a count. With `expanded` it is a shelf that folds ("Working",
/// "Settled (6)" while folded) with a chevron.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    /// Amber for what waits on you; otherwise quiet.
    var urgent = false
    var expanded: Binding<Bool>? = nil

    var body: some View {
        if let expanded {
            Button {
                Haptics.tap()
                withAnimation(Theme.reveal) { expanded.wrappedValue.toggle() }
            } label: {
                label(open: expanded.wrappedValue).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded.wrappedValue ? Text("Expanded") : Text("Collapsed"))
        } else {
            label(open: true).accessibilityAddTraits(.isHeader)
        }
    }

    private func label(open: Bool) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(verbatim: shownTitle(open: open))
                .font(Theme.TextStyle.section)
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(urgent ? Theme.amber : Theme.textTertiary)
                .lineLimit(1)
            if expanded != nil {
                Image(icon: "chevron.down")
                    .font(Theme.font(9, .bold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.sm)
    }

    /// "Settled (6)" while a shelf is folded or the count is what waits, "Working" while open.
    private func shownTitle(open: Bool) -> String {
        guard let count, count > 0, !open || urgent || expanded == nil else { return title }
        return "\(title) (\(count))"
    }
}

/// A session's state in a row's corner: its mark and one word in the state's color (Approval,
/// Input, Failed, Limit), the mark alone with "Working" while it works, and how long ago for the rest.
struct PhoneStatusLabel: View {
    let session: SessionDigest

    var body: some View {
        let attention = session.attention
        Group {
            if Theme.needsYou(attention) || attention == "working" || attention == "ready" {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(icon: Theme.symbol(attention))
                    Text(verbatim: Theme.shortWord(attention))
                }
                .font(Theme.textFont(11.5, .bold))
                .foregroundStyle(Theme.color(attention))
            } else {
                Text(verbatim: AgentRow.age(Date().timeIntervalSince1970 - session.updated))
                    .font(Theme.TextStyle.detail)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Theme.word(attention)))
    }
}

/// A session's state as a mark and a word, the Mac's `AgentStatusBadge` (`StatusBadgeLabel`): only the mark carries
/// the color; the word is grey, and paper-white when the session waits on you. The mark pulses while the agent works.
struct StatusPill: View {
    let attention: String
    /// The one-word form ("Approval", "Done") for a row's corner; the full words elsewhere.
    var short = false

    var body: some View {
        let color = Theme.color(attention)
        StatusBadgeLabel(word: short ? Theme.shortWord(attention) : Theme.word(attention), tint: color) {
            Group {
                if attention == "working" {
                    PulseDot(color: color, size: 6)
                } else {
                    Image(icon: Theme.symbol(attention))
                }
            }
            .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Theme.word(attention)))
    }
}

/// A live dot that breathes with an ambient radar ring, for work in progress; still with Reduce Motion.
struct PulseDot: View {
    let color: Color
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle().fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(on ? 1.9 : 1.0)
                    .opacity(on ? 0 : 0.45)
            }
            Circle().fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

/// Nook himself, as on the Mac: a round pearl lit like a ball (highlight top left, ambient bounce below, soft iris glow),
/// with expressive eyes that breathe and blink, and playful squish on tap.
struct NookMark: View {
    var size: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var blinking = false
    @State private var squishing = false

    var body: some View {
        ZStack {
            // Ambient soft glow
            Circle()
                .fill(Theme.iris.opacity(0.18))
                .frame(width: size * 1.1, height: size * 1.1)
                .blur(radius: size * 0.12)

            // Sphere base with specular highlight top-left and soft shadow bottom-right
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, Theme.iris, Color(hex: 0xCAC8D2), Color(hex: 0x8C8B96)],
                        center: UnitPoint(x: 0.34, y: 0.26),
                        startRadius: 0,
                        endRadius: size * 0.65
                    )
                )

            // Ambient lower bounce light
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Nook's soulful eyes with delicate catchlights
            HStack(spacing: size * 0.16) {
                eye
                eye
            }
            .offset(y: -size * 0.02)
            .scaleEffect(y: blinking ? 0.08 : 1, anchor: .center)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.iris.opacity(0.22), radius: size * 0.16, y: 1)
        .scaleEffect(
            x: squishing ? 1.14 : (breathing && !reduceMotion ? 1.015 : 0.985),
            y: squishing ? 0.86 : (breathing && !reduceMotion ? 0.985 : 1.015)
        )
        .contentShape(Circle())
        .onTapGesture { squish() }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3.5...5.5)))
                guard !reduceMotion else { continue }
                withAnimation(.easeInOut(duration: 0.1)) { blinking = true }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { blinking = false }
            }
        }
        .accessibilityHidden(true)
    }

    private var eye: some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Theme.ink)
                .frame(width: size * 0.095, height: size * 0.22)
            // Tiny eye shine
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: size * 0.035, height: size * 0.035)
                .offset(x: size * 0.015, y: size * 0.025)
        }
    }

    private func squish() {
        Haptics.tap()
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
            squishing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                squishing = false
            }
        }
    }
}

/// A short notice across the width of the screen (offline, push not ready, no brain), as the Mac's notices: on `surface`
/// with a faint edge; only its symbol carries the state color.
struct Banner: View {
    let text: String
    let symbol: String
    var color: Color = Theme.amber

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Image(icon: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(Theme.textStrong).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.TextStyle.detail)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md + Theme.Spacing.xxs)
        // notice: a wash of its color with an edge of it, so a warning reads as one at a glance.
        .cardBackground(color.opacity(0.1), stroke: color.opacity(0.32), radius: PhoneRadius.row + Theme.Spacing.xxs, style: .continuous)
    }
}

/// A light tap for what you just did from the phone.
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// The faint tick while an answer streams in (`StreamCadence` decides when).
    static func stream() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.45) }
}
