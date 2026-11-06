import AppKit
import XCTest

/// The picture that goes: the same one the preview shows, drawn from `ChatImageEdit`.
final class ChatImageRenderTests: XCTestCase {
    /// Twice as wide as high: red on the left half, blue on the right.
    private func picture(height: Int = 20) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: height * 2, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: height, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: height, y: 0, width: height, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func color(_ image: CGImage, x: Int, y: Int) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    func testACropKeepsThatPartOfThePicture() throws {
        var edit = ChatImageEdit()
        edit.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let made = try XCTUnwrap(ChatImageRender.render(try picture(), edit: edit))
        XCTAssertEqual(made.width, 20)
        XCTAssertEqual(made.height, 20)
        XCTAssertGreaterThan(try color(made, x: 10, y: 10).blue, 0.9)
    }

    func testATurnGoesClockwise() throws {
        var edit = ChatImageEdit()
        edit.rotate()
        let made = try XCTUnwrap(ChatImageRender.render(try picture(), edit: edit))
        XCTAssertEqual(made.width, 20)
        XCTAssertEqual(made.height, 40)
        // The left of the picture is now its top.
        XCTAssertGreaterThan(try color(made, x: 10, y: 5).red, 0.9)
        XCTAssertGreaterThan(try color(made, x: 10, y: 35).blue, 0.9)
    }

    func testALineLandsWhereItWasDrawn() throws {
        var edit = ChatImageEdit()
        edit.strokes = [.init(points: [CGPoint(x: 0, y: 0.25), CGPoint(x: 1, y: 0.25)], ink: .green)]
        // A line is a part of the picture's longest side wide, so this picture is big enough to show one.
        let made = try XCTUnwrap(ChatImageRender.render(try picture(height: 200), edit: edit))
        // A quarter down from the top: on the line, and not as far from the top at the bottom.
        XCTAssertGreaterThan(try color(made, x: 100, y: 50).green, 0.5)
        XCTAssertLessThan(try color(made, x: 100, y: 150).green, 0.3)
    }

    func testTextLandsWhereItWasPlacedAndUpright() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let blank = try XCTUnwrap(context.makeImage())
        var edit = ChatImageEdit()
        edit.labels = [.init(text: "WWW", center: CGPoint(x: 0.5, y: 0.25), ink: .white)]
        let made = try XCTUnwrap(ChatImageRender.render(blank, edit: edit))
        let rep = NSBitmapImageRep(cgImage: made)
        let lit = (0..<400).flatMap { y in (0..<400).map { (x: $0, y: y) } }
            .filter { (rep.colorAt(x: $0.x, y: $0.y)?.alphaComponent ?? 0) > 0.5 }
        XCTAssertFalse(lit.isEmpty)
        XCTAssertTrue(lit.allSatisfy { $0.y < 200 }, "the text is in the top half")
    }
}
