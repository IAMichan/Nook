#!/usr/bin/env swift
import AppKit

// Generates the Nook app icon for every platform from one drawing:
// - apps/macos/App/AppIcon.icns (macOS app icon)
// - apps/ios/NookCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png (iPhone companion)
// - apps/tauri/src-tauri/icons/icon.ico and the PNGs next to it (Windows and Linux app, installer, tray)
// Draws the Nook orb (soft white glowing circle with eyes) on a dark graphite squircle.

/// How the icon is laid out on its square canvas.
enum IconStyle {
    /// The macOS grid: an 824pt squircle with a 100pt margin, a drop shadow and a faint inner stroke.
    case macOS
    /// The squircle's contents fill the whole square, without shadow or stroke: iOS masks the icon itself and does
    /// not accept transparency.
    case fullBleed
    /// Windows and Linux: the rounded square fills the canvas up to a thin margin (Windows draws no shadow or margin
    /// of its own), so Nook is as large as the icons next to it in the taskbar and Start menu.
    case desktop
    /// The desktop icon at 16 to 32 pixels: no glow or stroke, and a larger orb with wider eyes, so the face stays
    /// readable in the title bar, the tray and Explorer's lists.
    case desktopSmall
}

/// Draws the icon on a 1024x1024 canvas in the given style.
func drawIcon(in ctx: CGContext, style: IconStyle) {
    let fullBleed = style == .fullBleed
    let desktop = style == .desktop || style == .desktopSmall
    let small = style == .desktopSmall
    // macOS icon grid: squircle 824x824 centered in 1024x1024 (100pt margin). Every style draws in this grid and
    // scales it up, so the orb keeps its size relative to the background.
    let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = desktop ? 170 : 185
    let squirclePath = fullBleed
        ? CGPath(rect: squircleRect, transform: nil)
        : CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    if style != .macOS {
        // Full bleed fills all 1024 points; the desktop styles keep a 32pt margin for antialiasing at small sizes.
        let scale: CGFloat = (fullBleed ? 1024 : 960) / 824
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -512, y: -512)
    }

    // Drop shadow below the squircle
    if style == .macOS {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.22))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()
    }

    // Background gradient within the squircle (dark graphite)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradientColors = [
        CGColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1.0),
        CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    }

    // Subtle inner stroke
    if style == .macOS || style == .desktop {
        ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.12))
        ctx.setLineWidth(3.0)
        ctx.addPath(squirclePath)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Nook Orb (soft white, NookTheme.iris)
    let orbCenter = CGPoint(x: 512, y: 512)
    let orbRadius: CGFloat = small ? 330 : 290
    let orbRect = CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2)

    // Glow behind the orb (left out at small sizes, where it only blurs the orb's edge)
    ctx.saveGState()
    if !small {
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 45, color: CGColor(red: 0.957, green: 0.953, blue: 0.969, alpha: 0.35))
    }
    ctx.setFillColor(CGColor(red: 0.957, green: 0.953, blue: 0.969, alpha: 1.0))
    ctx.fillEllipse(in: orbRect)
    ctx.restoreGState()

    // Orb spherical gradient
    ctx.saveGState()
    ctx.addEllipse(in: orbRect)
    ctx.clip()
    let orbColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.90, green: 0.89, blue: 0.93, alpha: 1.0)
    ] as CFArray
    if let orbGradient = CGGradient(colorsSpace: colorSpace, colors: orbColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(orbGradient, start: CGPoint(x: 512, y: 512 + orbRadius), end: CGPoint(x: 512, y: 512 - orbRadius), options: [])
    }
    ctx.restoreGState()

    // Eyes (deep midnight blue/black)
    let eyeWidth: CGFloat = small ? 84 : 64
    let eyeHeight: CGFloat = small ? 196 : 172
    let eyeY: CGFloat = small ? 1024 - 392 - eyeHeight : 1024 - 402 - eyeHeight
    let eyeCorner: CGFloat = eyeWidth / 2
    // The eyes' centers sit 83pt left and right of the middle (100pt in the small style).
    let eyeOffset: CGFloat = small ? 100 : 83

    let leftEyeRect = CGRect(x: 512 - eyeOffset - eyeWidth / 2, y: eyeY, width: eyeWidth, height: eyeHeight)
    let rightEyeRect = CGRect(x: 512 + eyeOffset - eyeWidth / 2, y: eyeY, width: eyeWidth, height: eyeHeight)
    let eyeColor = CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0)
    ctx.setFillColor(eyeColor)

    let leftPath = CGPath(roundedRect: leftEyeRect, cornerWidth: eyeCorner, cornerHeight: eyeCorner, transform: nil)
    ctx.addPath(leftPath)
    ctx.fillPath()

    let rightPath = CGPath(roundedRect: rightEyeRect, cornerWidth: eyeCorner, cornerHeight: eyeCorner, transform: nil)
    ctx.addPath(rightPath)
    ctx.fillPath()
}

func generateIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx, style: .macOS)
    image.unlockFocus()
    return image
}

/// The icon drawn at exactly `size` by `size` pixels with transparency (no Retina doubling).
func renderImage(size: Int, style: IconStyle) -> CGImage {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx, style: style)
    guard let image = ctx.makeImage() else { exit(1) }
    return image
}

func generatePNG(size: Int, style: IconStyle) -> Data {
    guard let png = NSBitmapImageRep(cgImage: renderImage(size: size, style: style))
        .representation(using: .png, properties: [:]) else { exit(1) }
    return png
}

/// An .ico image entry in the classic form every Windows tool reads: a 32-bit BGRA bitmap, bottom-up, with an
/// all-zero AND mask (the alpha channel does the masking).
func generateDIB(size: Int, style: IconStyle) -> Data {
    let rep = NSBitmapImageRep(cgImage: renderImage(size: size, style: style))
    var data = Data()
    func append16(_ value: Int) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
    func append32(_ value: Int) { append16(value & 0xFFFF); append16((value >> 16) & 0xFFFF) }
    let maskRowBytes = ((size + 31) / 32) * 4
    append32(40)            // BITMAPINFOHEADER size
    append32(size)          // width
    append32(size * 2)      // height: the color bitmap plus the AND mask
    append16(1)             // planes
    append16(32)            // bits per pixel
    append32(0)             // BI_RGB
    append32(size * size * 4 + maskRowBytes * size)
    append32(0); append32(0); append32(0); append32(0)
    for y in (0..<size).reversed() {
        for x in 0..<size {
            // colorAt gives straight (not premultiplied) components.
            let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
            func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            data.append(contentsOf: [byte(color.blueComponent), byte(color.greenComponent),
                                     byte(color.redComponent), byte(color.alphaComponent)])
        }
    }
    data.append(Data(count: maskRowBytes * size))
    return data
}

/// The desktop style for a size: the small variant up to 32 pixels, the full drawing above.
func desktopStyle(for size: Int) -> IconStyle { size <= 32 ? .desktopSmall : .desktop }

/// A Windows .ico with one image per size: bitmaps up to 64 pixels and a PNG for 256, the layout Windows' own icons
/// use and that NSIS, WiX and the resource compiler all accept.
func makeICO(sizes: [Int]) -> Data {
    let images = sizes.map { size in
        size >= 256 ? generatePNG(size: size, style: desktopStyle(for: size))
                    : generateDIB(size: size, style: desktopStyle(for: size))
    }
    var data = Data()
    func append16(_ value: Int) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
    func append32(_ value: Int) { append16(value & 0xFFFF); append16((value >> 16) & 0xFFFF) }
    append16(0)            // reserved
    append16(1)            // type: icon
    append16(sizes.count)  // number of images
    var offset = 6 + 16 * sizes.count
    for (size, png) in zip(sizes, images) {
        data.append(UInt8(size >= 256 ? 0 : size))  // width (0 means 256)
        data.append(UInt8(size >= 256 ? 0 : size))  // height
        data.append(0)         // palette size
        data.append(0)         // reserved
        append16(1)            // color planes
        append16(32)           // bits per pixel
        append32(png.count)
        append32(offset)
        offset += png.count
    }
    images.forEach { data.append($0) }
    return data
}

/// The iOS icon: 1024x1024 pixels, opaque (App Store Connect rejects an icon with an alpha channel).
func generateOpaqueIconPNG() -> Data {
    guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
    drawIcon(in: ctx, style: .fullBleed)
    guard let cgImage = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { exit(1) }
    return png
}

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = rootDir.appendingPathComponent("AppIcon.iconset")
let targetIcns = rootDir.appendingPathComponent("apps/macos/App/AppIcon.icns")
let targetIOSIcon = rootDir.appendingPathComponent("apps/ios/NookCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let tauriIconsDir = rootDir.appendingPathComponent("apps/tauri/src-tauri/icons")

// Windows and Linux (the Tauri app): the .ico for the app, its installer and the tray, and the PNGs Linux and the
// window use. The Android icons in icons/android are drawn separately.
try makeICO(sizes: [16, 20, 24, 32, 40, 48, 64, 256]).write(to: tauriIconsDir.appendingPathComponent("icon.ico"))
for (filename, px) in [("32x32.png", 32), ("64x64.png", 64), ("128x128.png", 128), ("128x128@2x.png", 256), ("icon.png", 512)] {
    try generatePNG(size: px, style: desktopStyle(for: px)).write(to: tauriIconsDir.appendingPathComponent(filename))
}
print("Successfully generated: \(tauriIconsDir.path)/icon.ico and PNGs")

try generateOpaqueIconPNG().write(to: targetIOSIcon)
print("Successfully generated: \(targetIOSIcon.path)")

try? fileManager.removeItem(at: iconsetDir)
try fileManager.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in specs {
    let img = generateIcon(size: px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        exit(1)
    }
    try png.write(to: iconsetDir.appendingPathComponent(filename))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", targetIcns.path]
try process.run()
process.waitUntilExit()

try? fileManager.removeItem(at: iconsetDir)

if process.terminationStatus == 0 {
    print("Successfully generated: \(targetIcns.path)")
} else {
    print("iconutil failed with code \(process.terminationStatus)")
    exit(1)
}
