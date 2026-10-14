#!/usr/bin/env swift
import AppKit

// Genereert App/AppIcon.icns voor Nook (macOS app-icoon).
// Tekent de Nook-orb (irispaarse gloeiende cirkel met ogen) op een subtiele lavendelkleurige squircle.

func generateIcon(size: Int) -> NSImage {
    let baseSize: CGFloat = 1024
    let scale = CGFloat(size) / baseSize
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

    ctx.scaleBy(x: scale, y: scale)

    // macOS icon grid: squircle 824x824 gecentreerd in 1024x1024 (100pt marge)
    let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185
    let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Slagschaduw onder de squircle
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.22))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.933, green: 0.918, blue: 1.0, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Achtergrondverloop binnen de squircle (zacht lavendel)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradientColors = [
        CGColor(red: 0.95, green: 0.94, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.91, green: 0.89, blue: 0.99, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    }

    // Subtiele binnenrand
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.6))
    ctx.setLineWidth(3.0)
    ctx.addPath(squirclePath)
    ctx.strokePath()
    ctx.restoreGState()

    // Nook Orb (iris paars, NookTheme.iris)
    let orbCenter = CGPoint(x: 512, y: 512)
    let orbRadius: CGFloat = 290
    let orbRect = CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2)

    // Gloed achter de orb
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 45, color: CGColor(red: 0.545, green: 0.482, blue: 1.0, alpha: 0.60))
    ctx.setFillColor(CGColor(red: 0.545, green: 0.482, blue: 1.0, alpha: 1.0))
    ctx.fillEllipse(in: orbRect)
    ctx.restoreGState()

    // Orb bolvormig verloop
    ctx.saveGState()
    ctx.addEllipse(in: orbRect)
    ctx.clip()
    let orbColors = [
        CGColor(red: 0.62, green: 0.56, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.50, green: 0.42, blue: 0.96, alpha: 1.0)
    ] as CFArray
    if let orbGradient = CGGradient(colorsSpace: colorSpace, colors: orbColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(orbGradient, start: CGPoint(x: 512, y: 512 + orbRadius), end: CGPoint(x: 512, y: 512 - orbRadius), options: [])
    }
    ctx.restoreGState()

    // Ogen (diep nachtblauw/zwart)
    let eyeWidth: CGFloat = 64
    let eyeHeight: CGFloat = 172
    let eyeY: CGFloat = 1024 - 402 - eyeHeight
    let eyeCorner: CGFloat = 32

    let leftEyeRect = CGRect(x: 397, y: eyeY, width: eyeWidth, height: eyeHeight)
    let rightEyeRect = CGRect(x: 563, y: eyeY, width: eyeWidth, height: eyeHeight)
    let eyeColor = CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0)
    ctx.setFillColor(eyeColor)

    let leftPath = CGPath(roundedRect: leftEyeRect, cornerWidth: eyeCorner, cornerHeight: eyeCorner, transform: nil)
    ctx.addPath(leftPath)
    ctx.fillPath()

    let rightPath = CGPath(roundedRect: rightEyeRect, cornerWidth: eyeCorner, cornerHeight: eyeCorner, transform: nil)
    ctx.addPath(rightPath)
    ctx.fillPath()

    image.unlockFocus()
    return image
}

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = rootDir.appendingPathComponent("AppIcon.iconset")
let targetIcns = rootDir.appendingPathComponent("App/AppIcon.icns")

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
    print("Succesvol aangemaakt: \(targetIcns.path)")
} else {
    print("iconutil mislukt met code \(process.terminationStatus)")
    exit(1)
}
