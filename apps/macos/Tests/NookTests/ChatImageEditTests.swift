import XCTest

/// What is done to a picture before it goes: the description, without any picture.
final class ChatImageEditTests: XCTestCase {
    private func assertEqual(_ a: CGRect, _ b: CGRect, line: UInt = #line) {
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 0.0001, line: line)
        }
    }

    func testANewEditLeavesThePictureAlone() {
        XCTAssertTrue(ChatImageEdit().isUntouched)
        var edit = ChatImageEdit()
        edit.labels.append(.init(text: "Hoi", center: CGPoint(x: 0.5, y: 0.5), ink: .red))
        XCTAssertFalse(edit.isUntouched)
    }

    func testFourTurnsComeBackToTheStart() {
        var edit = ChatImageEdit()
        edit.crop = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        edit.strokes = [.init(points: [CGPoint(x: 0.25, y: 0.75)], ink: .blue)]
        let start = edit
        for _ in 0..<4 { edit.rotate() }
        XCTAssertEqual(edit.turns, 0)
        assertEqual(edit.crop, start.crop)
        XCTAssertEqual(edit.strokes[0].points[0].x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(edit.strokes[0].points[0].y, 0.75, accuracy: 0.0001)
    }

    func testATurnTakesWhatIsOnThePictureAlong() {
        var edit = ChatImageEdit()
        edit.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.25)
        edit.labels = [.init(text: "a", center: CGPoint(x: 0.1, y: 0.2), ink: .white)]
        edit.rotate()
        // The top left corner goes to the top right.
        assertEqual(edit.crop, CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
        XCTAssertEqual(edit.labels[0].center.x, 0.8, accuracy: 0.0001)
        XCTAssertEqual(edit.labels[0].center.y, 0.1, accuracy: 0.0001)
    }

    func testACropStaysOnThePicture() {
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        assertEqual(ChatImageEdit.crop(crop, moving: .topLeft, by: CGSize(width: -1, height: -1)),
                    CGRect(x: 0, y: 0, width: 0.75, height: 0.75))
        assertEqual(ChatImageEdit.crop(crop, moving: .inside, by: CGSize(width: 1, height: -1)),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    func testACropCannotCollapse() {
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let squeezed = ChatImageEdit.crop(crop, moving: .right, by: CGSize(width: -1, height: 0))
        XCTAssertEqual(squeezed.width, ChatImageEdit.minimumCrop, accuracy: 0.0001)
        XCTAssertEqual(squeezed.minX, 0.25, accuracy: 0.0001)
        XCTAssertEqual(squeezed.height, 0.5, accuracy: 0.0001)
    }

    func testAPlaceOnACroppedPictureIsAPlaceOnTheWholeOne() {
        let window = CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertEqual(ChatImageEdit.point(CGPoint(x: 0.5, y: 0.5), in: window), CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(ChatImageEdit.point(CGPoint(x: 3, y: -1), in: window), CGPoint(x: 1, y: 0))
    }

    func testACropInPixelsIsNeverEmpty() {
        XCTAssertEqual(ChatImageEdit.pixels(of: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), width: 100, height: 40),
                       CGRect(x: 25, y: 20, width: 50, height: 10))
        XCTAssertEqual(ChatImageEdit.pixels(of: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001), width: 10, height: 10).width, 1)
    }
}
