import AppKit
import Combine

/// Draws the Nook app icon in the user's accent color and applies it as the running app's icon.
/// Mirrors `scripts/generate_app_icon.swift`, which produces the static default (white) `AppIcon.icns`.
@MainActor
enum AppIconRenderer {
    private static var bag = Set<AnyCancellable>()

    /// Applies the icon now and again whenever the accent color changes.
    static func start(settings: AppSettings) {
        apply(hex: settings.accentHex)
        settings.$accentHex
            .removeDuplicates()
            .sink { apply(hex: $0) }
            .store(in: &bag)
    }

    private static func apply(hex: UInt32) {
        // The default color keeps the bundled icon as is.
        NSApp.applicationIconImage = hex == NookTheme.defaultAccentHex ? nil : image(hex: hex)
    }

    static func image(hex: UInt32, size: CGFloat = 512) -> NSImage {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        func mix(_ t: CGFloat) -> CGColor {   // t > 0 lightens toward white, t < 0 darkens
            let target: CGFloat = t >= 0 ? 1 : 0
            let a = abs(t)
            return CGColor(red: r + (target - r) * a, green: g + (target - g) * a, blue: b + (target - b) * a, alpha: 1)
        }

        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let space = CGColorSpaceCreateDeviceRGB()
            ctx.scaleBy(x: size / 1024, y: size / 1024)

            let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
            let squircle = CGPath(roundedRect: squircleRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.22))
            ctx.addPath(squircle)
            ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(squircle)
            ctx.clip()
            let bg = [CGColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1), CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: bg, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
            }
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
            ctx.setLineWidth(3)
            ctx.addPath(squircle)
            ctx.strokePath()
            ctx.restoreGState()

            let radius: CGFloat = 290
            let orb = CGRect(x: 512 - radius, y: 512 - radius, width: radius * 2, height: radius * 2)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 45, color: CGColor(red: r, green: g, blue: b, alpha: 0.35))
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            ctx.fillEllipse(in: orb)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addEllipse(in: orb)
            ctx.clip()
            let orbColors = [mix(0.25), mix(-0.08)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: orbColors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 512 + radius), end: CGPoint(x: 512, y: 512 - radius), options: [])
            }
            ctx.restoreGState()

            let eyeY: CGFloat = 1024 - 402 - 172
            ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
            for x: CGFloat in [397, 563] {
                ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: eyeY, width: 64, height: 172), cornerWidth: 32, cornerHeight: 32, transform: nil))
                ctx.fillPath()
            }
            return true
        }
    }
}
