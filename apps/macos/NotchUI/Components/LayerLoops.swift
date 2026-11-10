import SwiftUI
import AppKit
import QuartzCore

/// Animations that loop for as long as an agent works (the pulse of a running session, the halo of a working dot, a
/// spinner, the dots while Nook writes), run by Core Animation instead of SwiftUI.
///
/// A SwiftUI timeline draws each frame on the main thread, and a timeline in a `SeparateGraph` still made AppKit lay out
/// the whole window around it on every frame (its hosting view marks the window as needing layout and constraints): with
/// a dozen sessions at work the main window was laid out more than a hundred times a second. Here the animation is
/// handed to the render server once; the main thread does nothing per frame. `fps` caps the rate the render server draws
/// it at (`EnergyPlan`), and 0 holds it still, as a paused `.nookFrames` timeline does.
struct LayerLoop: NSViewRepresentable {
    enum Shape: Equatable {
        /// A ring of `diameter` that grows by `growth` (1.3: to 2.3 times its size) and fades from `opacity`, easing out.
        case ring(diameter: CGFloat, lineWidth: CGFloat, growth: CGFloat, opacity: Double, period: Double)
        /// A filled disc of `diameter` that grows by `growth` and fades from `opacity`, evenly.
        case halo(diameter: CGFloat, growth: CGFloat, opacity: Double, period: Double)
        /// An arc of `length` (0...1 of the circle) that turns clockwise once every `period`, as large as the view.
        case spinner(lineWidth: CGFloat, length: CGFloat, period: Double)
        /// `count` dots in a row that rise by `rise` and brighten from `low` to `high` opacity in turn, as a wave.
        case wave(count: Int, diameter: CGFloat, spacing: CGFloat, rise: CGFloat, low: Double, high: Double, period: Double,
                  lag: Double)
        /// A light along every edge of the view, `thickness` deep, fading inward, with a thin line on the edge itself; it
        /// breathes between `low` and `high` opacity. The glow over a browser an agent drives (`BrowserTakeoverOverlay`).
        case edgeGlow(thickness: CGFloat, low: Double, high: Double, period: Double)
    }

    let shape: Shape
    let color: Color
    /// Frames a second at most (`EnergyPlan.progressFrameRate`); 0 holds the first frame still.
    let fps: Double

    func makeNSView(context: Context) -> LoopLayerView {
        let view = LoopLayerView()
        view.configure(shape: shape, color: color, fps: fps)
        return view
    }

    func updateNSView(_ view: LoopLayerView, context: Context) {
        view.configure(shape: shape, color: color, fps: fps)
    }
}

/// The view behind `LayerLoop`: builds the layers for its shape at its size and gives them their animation. Takes no
/// clicks or hover; the views around it keep those.
final class LoopLayerView: NSView {
    private var shape: LayerLoop.Shape?
    private var color: Color = .clear
    private var fps: Double = 0
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func configure(shape: LayerLoop.Shape, color: Color, fps: Double) {
        guard shape != self.shape || color != self.color || fps != self.fps else { return }
        self.shape = shape
        self.color = color
        self.fps = fps
        rebuild()
    }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Back on screen: the animations start again in step with the clock.
        if window != nil { rebuild() }
    }

    private func rebuild() {
        guard let layer, let shape else { return }
        builtSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let cgColor = LayerLoopTiming.resolve(color, in: self)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        switch shape {
        case .ring(let diameter, let lineWidth, let growth, let opacity, let period):
            let ring = CAShapeLayer()
            ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ring.position = center
            ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
            ring.fillColor = nil
            ring.strokeColor = cgColor
            ring.lineWidth = lineWidth
            ring.opacity = Float(opacity)
            layer.addSublayer(ring)
            // 1 - (1 - t)², as the timeline drew it.
            let easeOut = CAMediaTimingFunction(controlPoints: 0.33, 0.67, 0.67, 1)
            LayerLoopTiming.add([
                LayerLoopTiming.basic("transform.scale", from: 1, to: 1 + growth),
                LayerLoopTiming.basic("opacity", from: opacity, to: 0)
            ], to: ring, period: period, timing: easeOut, fps: fps)
        case .halo(let diameter, let growth, let opacity, let period):
            let halo = CALayer()
            halo.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            halo.position = center
            halo.cornerRadius = diameter / 2
            halo.backgroundColor = cgColor
            halo.opacity = Float(opacity)
            layer.addSublayer(halo)
            LayerLoopTiming.add([
                LayerLoopTiming.basic("transform.scale", from: 1, to: 1 + growth),
                LayerLoopTiming.basic("opacity", from: opacity, to: 0)
            ], to: halo, period: period, timing: CAMediaTimingFunction(name: .linear), fps: fps)
        case .spinner(let lineWidth, let length, let period):
            let arc = CAShapeLayer()
            arc.bounds = bounds
            arc.position = center
            arc.path = CGPath(ellipseIn: bounds, transform: nil)
            arc.fillColor = nil
            arc.strokeColor = cgColor
            arc.lineWidth = lineWidth
            arc.lineCap = .round
            arc.strokeEnd = length
            layer.addSublayer(arc)
            // Flipped geometry: a positive angle turns clockwise, as `rotationEffect` does.
            LayerLoopTiming.add([LayerLoopTiming.basic("transform.rotation.z", from: 0, to: 2 * Double.pi)],
                                to: arc, period: period, timing: CAMediaTimingFunction(name: .linear), fps: fps)
        case .wave(let count, let diameter, let spacing, let rise, let low, let high, let period, let lag):
            let width = CGFloat(count) * diameter + CGFloat(max(0, count - 1)) * spacing
            // (sin + 1) / 2 over one period, sampled finely enough that the straight lines between read as a curve.
            let steps = 24
            let wave = (0...steps).map { (sin(2 * Double.pi * Double($0) / Double(steps)) + 1) / 2 }
            for index in 0..<count {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                dot.position = CGPoint(x: bounds.midX - width / 2 + diameter / 2 + CGFloat(index) * (diameter + spacing),
                                       y: center.y)
                dot.cornerRadius = diameter / 2
                dot.backgroundColor = cgColor
                dot.opacity = Float(low)
                layer.addSublayer(dot)
                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = wave.map { low + (high - low) * $0 }
                // Up is toward the top: negative in flipped geometry.
                let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
                lift.values = wave.map { -rise * $0 }
                LayerLoopTiming.add([opacity, lift], to: dot, period: period, timing: nil, fps: fps,
                                    lag: Double(index) * lag)
            }
        case .edgeGlow(let thickness, let low, let high, let period):
            // One layer holds the four lights and the line, so a single opacity animation makes them breathe together.
            let glow = CALayer()
            glow.frame = bounds
            glow.opacity = Float(high)
            let clear = cgColor.copy(alpha: 0) ?? cgColor
            let depth = min(thickness, bounds.width / 2, bounds.height / 2)
            // Each light runs from its edge (start) inward (end); flipped geometry, so y 0 is the top.
            let edges: [(CGRect, CGPoint, CGPoint)] = [
                (CGRect(x: 0, y: 0, width: bounds.width, height: depth), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
                (CGRect(x: 0, y: bounds.height - depth, width: bounds.width, height: depth), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (CGRect(x: 0, y: 0, width: depth, height: bounds.height), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
                (CGRect(x: bounds.width - depth, y: 0, width: depth, height: bounds.height), CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
            ]
            for (frame, start, end) in edges {
                let light = CAGradientLayer()
                light.frame = frame
                light.colors = [cgColor.copy(alpha: 0.55) ?? cgColor, cgColor.copy(alpha: 0.12) ?? cgColor, clear]
                light.locations = [0, 0.35, 1]
                light.startPoint = start
                light.endPoint = end
                glow.addSublayer(light)
            }
            let line = CALayer()
            line.frame = bounds
            line.borderColor = cgColor
            line.borderWidth = 2
            glow.addSublayer(line)
            layer.addSublayer(glow)
            let breathe = CAKeyframeAnimation(keyPath: "opacity")
            breathe.values = [high, low, high]
            breathe.keyTimes = [0, 0.5, 1]
            LayerLoopTiming.add([breathe], to: glow, period: period, timing: CAMediaTimingFunction(name: .easeInEaseOut), fps: fps)
        }
    }
}

/// An SF Symbol that pulses or turns for as long as something runs, drawn by Core Animation.
///
/// `.symbolEffect(_, options: .repeating)` is a SwiftUI animation like any other: it lays out and updates the whole window
/// it is in at the display's own rate (100 times a second measured, one rotating check in a sidebar was enough), for as
/// long as the symbol is on screen. Here the render server turns the picture; the main thread does nothing per frame.
/// Inactive, or when you asked for less motion, it is the plain symbol and lays out as one.
struct LayerSymbol: View {
    enum Motion: Equatable {
        /// Fades to a third and back.
        case pulse
        /// One clockwise turn every period.
        case rotate

        var period: Double {
            switch self {
            case .pulse: return 1.6
            case .rotate: return 2
            }
        }
    }

    let name: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    let color: Color
    let motion: Motion
    var active = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Published only when the plan changes: sets how often the render server draws it.
    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended
    @State private var visible = false

    var body: some View {
        // The plain symbol keeps the size; the turning one lies over it, and the plain one is hidden meanwhile.
        let turning = active && visible && !reduceMotion
        Image(icon: name)
            .font(NookTheme.font(size, weight))
            .foregroundStyle(color)
            .opacity(turning ? 0 : 1)
            .overlay {
                if turning {
                    LayerSymbolView(name: name, size: size, weight: weight, color: color, motion: motion,
                                    fps: energy.plan.progressFrameRate(attended: attended))
                        .allowsHitTesting(false)
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }
}

struct LayerSymbolView: NSViewRepresentable {
    let name: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    let motion: LayerSymbol.Motion
    let fps: Double

    func makeNSView(context: Context) -> SymbolLayerView {
        let view = SymbolLayerView()
        view.configure(self)
        return view
    }

    func updateNSView(_ view: SymbolLayerView, context: Context) {
        view.configure(self)
    }

    /// Whether this draws the same as `other`, so an update of the window around it leaves the running loop alone.
    func same(as other: LayerSymbolView?) -> Bool {
        guard let other else { return false }
        return name == other.name && size == other.size && weight == other.weight && color == other.color
            && motion == other.motion && fps == other.fps
    }
}

/// The view behind `LayerSymbol`: one layer with the symbol's picture, centered, with its loop. Takes no clicks or hover.
final class SymbolLayerView: NSView {
    private var spec: LayerSymbolView?
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func configure(_ spec: LayerSymbolView) {
        guard !spec.same(as: self.spec) else { return }
        self.spec = spec
        rebuild()
    }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Back on screen: the animation starts again in step with the clock.
        if window != nil { rebuild() }
    }

    private func rebuild() {
        guard let layer, let spec else { return }
        builtSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let configuration = NSImage.SymbolConfiguration(pointSize: spec.size, weight: Self.weight(spec.weight))
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: LayerLoopTiming.resolve(spec.color, in: self)) ?? .white]))
        guard let image = NookIcon.nsImage(spec.name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return }
        let picture = CALayer()
        picture.contentsScale = image.recommendedLayerContentsScale(scale)
        picture.contents = image.layerContents(forContentsScale: picture.contentsScale)
        picture.contentsGravity = .center
        picture.bounds = CGRect(origin: .zero, size: image.size)
        picture.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.addSublayer(picture)
        let period = spec.motion.period
        switch spec.motion {
        case .pulse:
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1.0, 0.33, 1.0]
            fade.keyTimes = [0, 0.5, 1]
            fade.duration = period
            LayerLoopTiming.add([fade], to: picture, period: period, timing: CAMediaTimingFunction(name: .easeInEaseOut), fps: spec.fps)
        case .rotate:
            // Clockwise: in a layer that is not flipped, that is a falling angle.
            let turn = LayerLoopTiming.basic("transform.rotation.z", from: 0, to: -2 * .pi)
            turn.duration = period
            LayerLoopTiming.add([turn], to: picture, period: period, timing: nil, fps: spec.fps)
        }
    }

    private static func weight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

/// The parts every looping layer shares: one clock, the frame rate cap, colors in the window's appearance.
@MainActor
enum LayerLoopTiming {
    static func basic(_ keyPath: String, from: Double, to: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    /// Loops `animations` on `layer` every `period`, at most `fps` frames a second; `fps` 0 adds nothing (it holds still).
    /// The loop is in step with the wall clock, as the `.nookFrames` timelines were: every working dot pulses together,
    /// also one that appeared later. `lag` runs this one that much behind.
    static func add(_ animations: [CAAnimation], to layer: CALayer, period: Double, timing: CAMediaTimingFunction?,
                    fps: Double, lag: Double = 0) {
        guard fps > 0, period > 0 else { return }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = period
        group.repeatCount = .infinity
        if let timing { group.timingFunction = timing }
        let rate = Float(fps)
        group.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 8), maximum: rate, preferred: rate)
        let phase = (Date().timeIntervalSinceReferenceDate - lag).truncatingRemainder(dividingBy: period)
        group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - phase
        group.fillMode = .backwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "loop")
    }

    /// `color` as the view's appearance shows it (light or dark), for a layer.
    static func resolve(_ color: Color, in view: NSView) -> CGColor {
        var resolved = NSColor(color).cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).cgColor
        }
        return resolved
    }
}

/// A light that runs over a line of text, left to right, every `period`: the step an agent runs now. The text itself is
/// drawn by SwiftUI beneath it; this view only holds the light, cut to the text's shape. That shape is drawn once for
/// each text and size (`mask`), and the light moves in the render server, so the main thread does nothing per frame.
struct ShimmerLayer: NSViewRepresentable {
    /// The text as SwiftUI lays it out at the view's size: the light's shape.
    let mask: AnyView
    /// What changes the mask's shape: the text and how it is set.
    let maskKey: String
    let color: Color
    let fps: Double
    var period: Double = 2.2
    /// Half the width of the light, as a share of the text's width.
    var spread: Double = 0.15

    func makeNSView(context: Context) -> ShimmerLayerView { ShimmerLayerView() }

    func updateNSView(_ view: ShimmerLayerView, context: Context) {
        view.configure(self)
    }
}

final class ShimmerLayerView: NSView {
    private var setting: (key: String, color: Color, fps: Double, period: Double, spread: Double)?
    private var mask: AnyView = AnyView(EmptyView())
    private var maskedSize: CGSize = .zero
    private var maskedKey = ""
    private let light = CAGradientLayer()
    private let shape = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        light.mask = shape
        layer?.addSublayer(light)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func configure(_ shimmer: ShimmerLayer) {
        mask = shimmer.mask
        let next = (shimmer.maskKey, shimmer.color, shimmer.fps, shimmer.period, shimmer.spread)
        if let setting, setting.key == next.0, setting.color == next.1, setting.fps == next.2, setting.period == next.3,
           setting.spread == next.4 {
            return
        }
        let animationChanged = setting.map { $0.color != next.1 || $0.fps != next.2 || $0.period != next.3 || $0.spread != next.4 } ?? true
        setting = next
        if animationChanged { restart() }
        drawMask()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.frame = bounds
        shape.frame = bounds
        CATransaction.commit()
        drawMask()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restart()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            maskedSize = .zero
            drawMask()
            restart()
        }
    }

    /// The text's shape at this size, drawn once per text and size, at the screen's scale.
    private func drawMask() {
        guard let setting, bounds.width > 0, bounds.height > 0,
              bounds.size != maskedSize || setting.key != maskedKey else { return }
        maskedSize = bounds.size
        maskedKey = setting.key
        let renderer = ImageRenderer(content: mask.frame(width: bounds.width, height: bounds.height, alignment: .topLeading))
        renderer.scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.contentsScale = renderer.scale
        shape.contents = renderer.cgImage
        CATransaction.commit()
    }

    private func restart() {
        guard let setting else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let paper = LayerLoopTiming.resolve(setting.color, in: self)
        let clear = paper.copy(alpha: 0) ?? paper
        light.colors = [clear, paper, clear]
        let spread = setting.spread
        // At rest (held still) the light sits just before the text, out of sight.
        light.locations = [-2 * spread, -spread, 0].map { NSNumber(value: $0) }
        light.removeAllAnimations()
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [-spread, 0, spread]
        move.toValue = [1 - spread, 1, 1 + spread]
        LayerLoopTiming.add([move], to: light, period: setting.period, timing: CAMediaTimingFunction(name: .linear),
                            fps: setting.fps)
    }
}

/// Bars that follow live levels (`levels`, each 0...1), read `fps` times a second on the main thread and set straight on
/// their layers: no SwiftUI update and no layout of the window around them per frame. Grown from the bottom.
struct LayerLevelBars: NSViewRepresentable {
    let count: Int
    let barWidth: CGFloat
    let spacing: CGFloat
    let color: Color
    /// Frames a second; 0 holds the bars where they are.
    let fps: Double
    let levels: () -> [Double]

    func makeNSView(context: Context) -> LayerLevelBarsView { LayerLevelBarsView() }

    func updateNSView(_ view: LayerLevelBarsView, context: Context) {
        view.configure(self)
    }
}

final class LayerLevelBarsView: NSView {
    private var bars: [CALayer] = []
    private var setting: LayerLevelBars?
    private var timer: Timer?
    private var color: Color = .clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func configure(_ bars: LayerLevelBars) {
        let previous = setting
        setting = bars
        if previous?.count != bars.count || previous?.color != bars.color { build() }
        if previous?.fps != bars.fps || timer == nil { schedule() }
        tick()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedule()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        build()
    }

    override func layout() {
        super.layout()
        tick()
    }

    private func build() {
        guard let layer, let setting else { return }
        bars.forEach { $0.removeFromSuperlayer() }
        let cgColor = LayerLoopTiming.resolve(setting.color, in: self)
        bars = (0..<setting.count).map { _ in
            let bar = CALayer()
            bar.backgroundColor = cgColor
            bar.cornerRadius = setting.barWidth / 2
            layer.addSublayer(bar)
            return bar
        }
        tick()
    }

    /// Reads the levels while the bars are in a window; off screen (`viewDidMoveToWindow` with none) the timer stops.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard window != nil, let fps = setting?.fps, fps > 0 else { return }
        timer = Timer.scheduledCoalesced(withTimeInterval: 1 / fps) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let setting, !bars.isEmpty else { return }
        let levels = setting.levels()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let level = index < levels.count ? max(0, min(1, levels[index])) : 0
            let height = max(setting.barWidth, bounds.height * CGFloat(level))
            bar.frame = CGRect(x: CGFloat(index) * (setting.barWidth + setting.spacing), y: bounds.height - height,
                               width: setting.barWidth, height: height)
        }
        CATransaction.commit()
    }
}
