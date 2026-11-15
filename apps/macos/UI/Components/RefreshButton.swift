import AppKit
import SwiftUI

/// The refresh symbol, the same everywhere a page can be read again: the sidebar footer, the Pull requests page and a
/// pull request's own page.
enum RefreshSymbol {
    static let name = "arrow.triangle.2.circlepath"
}

/// A refresh button in the look of `NookIconButton` whose arrows turn while `turning`, so you see the read is still
/// running. The click stays live while it turns: a page that is already reading reads again once it is done.
struct RefreshIconButton: View {
    let label: String
    let turning: Bool
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TurningGlyph(symbol: RefreshSymbol.name, turning: turning,
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
        .accessibilityValue(turning ? tr("a11y.loading") : "")
    }
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

    private func updateTurn() {
        guard turning, window != nil else {
            symbolLayer.removeAnimation(forKey: Self.turnKey)
            return
        }
        guard symbolLayer.animation(forKey: Self.turnKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        // Clockwise: the layer's y axis points up.
        turn.toValue = -2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        symbolLayer.add(turn, forKey: Self.turnKey)
    }
}
