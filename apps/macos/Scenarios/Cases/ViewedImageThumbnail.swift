import AppKit

/// Proves e9ceecc7 ("viewed images"): a picture the agent only looked at with Read shows as a thumbnail under the step.
final class ViewedImageThumbnail: Scenario {
    func testViewedImageThumbnail() throws {
        try scenario("A picture the agent read shows as a thumbnail under its step") { nook, screen, app in
            let project = try nook.project("brand", files: ["Assets/logo.png": Self.logo()])
            let session = try nook.session(project: project, title: "Check the logo", messages: ["Is the logo fine?"],
                                                 recording: "viewed-image")
            try nook.open(session)

            // The turn is on screen: what follows is about the picture, not about a turn that did not show.
            try expect(screen.text("Nothing in it needs to change")).toBeVisible()
            // The finished turn folds its work away: open it, where the step that read the picture is.
            try screen.button("Worked for", exact: false).tap()
            try app.screenshot("turn")
            try expect(screen.labelled("Images the agent viewed")).toBeVisible(timeout: 5)
            try app.screenshot("thumbnail")
        }
    }

    /// A 64 × 64 PNG: a plain violet square.
    static func logo() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 {
            for y in 0..<64 {
                image.setColor(NSColor(deviceRed: 0.45, green: 0.4, blue: 0.95, alpha: 1), atX: x, y: y)
            }
        }
        return image.representation(using: .png, properties: [:]) ?? Data()
    }
}
