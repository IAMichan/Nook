import SwiftUI
import AppKit

// Feedback parts of the motion language (`NookTheme.Motion`): a skeleton where content is on its way, and the "Copied"
// confirmation that stands beside what was copied.

/// A quiet placeholder for content that is loading: a soft wash in the shape of what will come, breathing slowly (Core
/// Animation, so the main thread does nothing per frame; still with Reduce Motion). Use a few of them in the layout of the
/// real content instead of a spinner; `PatientSpinner` stays for a pane with no known shape.
struct NookSkeleton: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var radius: CGFloat = NookTheme.Radius.chip

    var body: some View {
        SkeletonPulse()
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .roundedBackground(NookTheme.wash.opacity(0.07), radius: radius)
            .roundedClip(radius)
            .accessibilityHidden(true)
    }
}

/// Lines of text as skeletons; the last one is shorter, as a paragraph's is.
struct NookSkeletonLines: View {
    var lines = 3
    var lineHeight: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ForEach(0..<max(1, lines), id: \.self) { index in
                NookSkeleton(width: index == lines - 1 && lines > 1 ? 160 : nil, height: lineHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("loading.label"))
    }
}

private struct SkeletonPulse: NSViewRepresentable {
    func makeNSView(context: Context) -> SkeletonPulseView { SkeletonPulseView() }
    func updateNSView(_ view: SkeletonPulseView, context: Context) { view.refresh() }
}

private final class SkeletonPulseView: NSView {
    private let glow = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        glow.opacity = 0
        layer?.addSublayer(glow)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glow.frame = bounds
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glow.backgroundColor = NSColor(NookTheme.wash).cgColor
        }
        glow.removeAnimation(forKey: "pulse")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0
        pulse.toValue = 0.06
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "pulse")
    }
}

/// "Copied" with a checkmark, a small confirmation to put beside what was just copied (a code block's header, a link). It
/// follows a `CopiedMoment`: shown for its 1.5 s, fading with the quick curve. A copy button shows the same on itself
/// (`CopyIconButton`, `CopyGhostButton`); this is for a place with no button to turn into a checkmark.
struct CopiedBadge: View {
    var shown: Bool

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(icon: "checkmark").font(NookTheme.TextStyle.label)
            Text(tr("button.copied")).font(NookTheme.TextStyle.label)
        }
        .foregroundStyle(NookTheme.mint)
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.xs)
        .roundedBackground(NookTheme.mint.opacity(0.12), radius: NookTheme.Radius.chip)
        .opacity(shown ? 1 : 0)
        .nookAnimation(NookTheme.Motion.quick, value: shown)
        .accessibilityHidden(!shown)
    }
}
