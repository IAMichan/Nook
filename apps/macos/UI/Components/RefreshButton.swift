import AppKit
import SwiftUI

/// The refresh symbol, the same everywhere a page can be read again: the sidebar footer, the Pull requests page and a
/// pull request's own page.
enum RefreshSymbol {
    static let name = "arrow.triangle.2.circlepath"
}

/// A refresh button in the look of `NookIconButton` whose arrows turn while `turning`, so you see the read is still
/// running. The click stays live while it turns: a page that is already reading reads again once it is done.
/// Every click turns the arrows at least once, also when the read is over in a blink or was folded into one already
/// running: a click with nothing moving reads as a button that does not work.
struct RefreshIconButton: View {
    let label: String
    let turning: Bool
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false
    /// Bumped by each click; the arrows keep turning until the turn it started is done.
    @State private var clicks = 0
    @State private var acknowledged = 0

    var body: some View {
        Button {
            clicks += 1
            let click = clicks
            action()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(RefreshIconButton.minimumTurn * 1_000_000_000))
                acknowledged = max(acknowledged, click)
            }
        } label: {
            TurningGlyph(symbol: RefreshSymbol.name, turning: turning || clicks > acknowledged,
                         color: hovering ? NookTheme.paper : NookTheme.textSecondary,
                         pointSize: size * 0.42, weight: .semibold)
                .frame(width: size, height: size)
                .roundedBackground(hovering ? NookTheme.graphite : Color.clear, radius: NookTheme.Radius.control)
                .hoverLift(hovering, scale: 1.03)
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .nookTip(label)
        .accessibilityLabel(label)
        .accessibilityValue(turning || clicks > acknowledged ? tr("a11y.loading") : "")
    }

    /// One full turn of `TurningGlyph`.
    static let minimumTurn: TimeInterval = 1
}

/// A symbol that turns once a second while `turning`. Core Animation turns it, not a SwiftUI timeline: a refresh is
/// exactly when the main thread is busy (the Keychain read, the app redrawing when the scan comes in), and every
/// timeline frame waited for it there, so the arrow stuttered and looked stuck. The render server turns the layer on
/// its own and the window is not laid out for it. It stands still with Reduce Motion on and while the energy plan
/// pauses animations.
struct TurningGlyph: View {
    let symbol: String
    let turning: Bool
    let color: Color
    /// The size and weight of `NookTheme.TextStyle.body` by default, which `ToolGlyph` draws its symbol in.
    var pointSize: CGFloat = 13.5
    var weight: NSFont.Weight = .regular
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TurningSymbol(symbol: symbol, color: NSColor(color), pointSize: pointSize, weight: weight,
                      turning: turning && !reduceMotion && energy.plan.pace != .paused)
            .frame(width: 16, height: 16)
    }
}

private struct TurningSymbol: NSViewRepresentable {
    let symbol: String
    let color: NSColor
    let pointSize: CGFloat
    let weight: NSFont.Weight
    let turning: Bool

    func makeNSView(context: Context) -> TurningSymbolView { TurningSymbolView() }

    func updateNSView(_ view: TurningSymbolView, context: Context) {
        view.show(.init(symbol: symbol, color: color, pointSize: pointSize, weight: weight))
        view.turning = turning
    }
}

private final class TurningSymbolView: NSView {
    struct Look: Equatable {
        let symbol: String
        let color: NSColor
        let pointSize: CGFloat
        let weight: NSFont.Weight
    }

    private let symbolLayer = CALayer()
    private var shown: Look?
    private static let turnKey = "turn"
    private static let settleKey = "settle"

    var turning = false {
        didSet { if turning != oldValue { updateTurn() } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        symbolLayer.contentsGravity = .center
        layer?.addSublayer(symbolLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Turned around its middle: a sublayer, so AppKit does not move its anchor back.
        symbolLayer.bounds = bounds
        symbolLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        draw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        draw()
        // A layer leaving its window drops its animations.
        updateTurn()
    }

    func show(_ look: Look) {
        if shown == look { return }
        shown = look
        draw()
    }

    private func draw() {
        guard let shown else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: shown.pointSize, weight: shown.weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [shown.color]))
        let image = NookIcon.nsImage(shown.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.contentsScale = scale
        symbolLayer.contents = image?.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }

    /// Turning starts from where the arrows stand; stopping lets them finish the turn they are in, so they come to rest
    /// upright instead of jumping back.
    private func updateTurn() {
        guard window != nil else {
            symbolLayer.removeAllAnimations()
            return
        }
        if turning {
            guard symbolLayer.animation(forKey: Self.turnKey) == nil else { return }
            let from = currentAngle()
            symbolLayer.removeAnimation(forKey: Self.settleKey)
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = from
            // Clockwise: the layer's y axis points up.
            turn.toValue = from - 2 * Double.pi
            turn.duration = 1
            turn.repeatCount = .infinity
            symbolLayer.add(turn, forKey: Self.turnKey)
        } else {
            guard symbolLayer.animation(forKey: Self.turnKey) != nil else { return }
            let from = currentAngle()
            symbolLayer.removeAnimation(forKey: Self.turnKey)
            // What is left of this turn, at the same speed; the layer itself stands at 0, which is a full turn.
            let left = 2 * Double.pi + from
            guard left > 0.01 else { return }
            let settle = CABasicAnimation(keyPath: "transform.rotation.z")
            settle.fromValue = from
            settle.toValue = -2 * Double.pi
            settle.duration = left / (2 * Double.pi)
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            symbolLayer.add(settle, forKey: Self.settleKey)
        }
    }

    /// The angle the arrows show now, in (-2π, 0]: clockwise turns count down from 0.
    private func currentAngle() -> Double {
        guard let angle = symbolLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double else { return 0 }
        let turned = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        return turned > 0 ? turned - 2 * Double.pi : turned
    }
}
