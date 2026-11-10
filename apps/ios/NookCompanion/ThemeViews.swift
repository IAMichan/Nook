import SwiftUI
import UIKit

// The phone's own views, built on the parts it shares with the Mac (apps/macos/NotchUI/Shared): each one draws as its
// counterpart in Nook on the Mac, with touch instead of hover. Change the shared part, not a copy of it here.

// MARK: Surfaces

extension View {
    /// What belongs together on one card, the Mac's `panelCard`: the field fill and the panel's corners, no stroke. With
    /// `tint` (something that waits on you, an error) it is a notice, as the Mac's `PanelNoticeBar`: `surface` with a
    /// faint edge in that color.
    @ViewBuilder
    func card(padding: CGFloat = Theme.Spacing.xl, tint: Color? = nil) -> some View {
        let content = self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        if let tint {
            content.cardBackground(Theme.surface, stroke: tint.opacity(0.35), radius: Theme.Radius.panel, style: .continuous)
        } else {
            content.panelCard()
        }
    }

    /// The dark canvas behind a whole screen, with matching bars.
    func screen() -> some View {
        self
            .background(Theme.canvas.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
    }
}

/// A group's name above it ("Recent", "On MacBook"), the Mac's `NookSectionLabel`, with a count: amber
/// (`NookCountBadge`) for what waits on you, else a quiet number. With `expanded` it is a shelf that folds, the Mac's
/// `NookShelfHeader`: "Working (3)", a line, and a chevron.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    /// Amber count for what waits on you; otherwise the count is a quiet number.
    var urgent = false
    var expanded: Binding<Bool>? = nil

    var body: some View {
        if let expanded {
            NookShelfHeader(title: title, count: count, open: expanded.wrappedValue) {
                Haptics.tap()
                withAnimation(Theme.reveal) { expanded.wrappedValue.toggle() }
            }
            .padding(.top, Theme.Spacing.md)
        } else {
            HStack(spacing: Theme.Spacing.sm) {
                NookSectionLabel(title, inset: 0)
                if let count {
                    if urgent {
                        NookCountBadge(count: count)
                    } else {
                        Text(count, format: .number).font(Theme.TextStyle.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xs)
        }
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
        .cardBackground(Theme.surface, stroke: Theme.line2, radius: Theme.Radius.panel, style: .continuous)
    }
}

/// A light tap for what you just did from the phone.
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
