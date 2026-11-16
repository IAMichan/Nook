import XCTest

/// One list of file names for every chat app and every link: a file in a chat and a link to one are told apart the same.
final class ChatMediaKindsTests: XCTestCase {
    func testALinkAndAFileGoByTheSameNames() {
        for ext in ChatMedia.pictureExtensions {
            XCTAssertEqual(ChatMedia.kind(name: "a." + ext), .photo, ext)
            XCTAssertEqual(ChatFormat.linkKind(URL(string: "https://a.com/a." + ext)!), .image, ext)
        }
        for ext in ChatMedia.videoExtensions {
            XCTAssertEqual(ChatMedia.kind(name: "a." + ext), .video, ext)
            XCTAssertEqual(ChatFormat.linkKind(URL(string: "https://a.com/a." + ext)!), .video, ext)
        }
        for ext in ChatMedia.audioExtensions {
            XCTAssertEqual(ChatMedia.kind(name: "a." + ext), .audio, ext)
            XCTAssertEqual(ChatFormat.linkKind(URL(string: "https://a.com/a." + ext)!), .audio, ext)
        }
        XCTAssertEqual(ChatFormat.linkKind(URL(string: "https://a.com/cat.GIF")!), .image)
        XCTAssertEqual(ChatFormat.linkKind(URL(string: "https://a.com/photo.avif")!), .image, "a picture link the old list missed")
        XCTAssertEqual(ChatFormat.linkKind(URL(string: "https://a.com/clip.webm")!), .page, "this Mac plays no WebM: the page opens it")
        XCTAssertEqual(ChatFormat.linkKind(URL(string: "https://a.com/plan.pdf")!), .page)
    }

    func testOnePlaceholderPerKind() {
        XCTAssertEqual(ChatMedia(kind: .photo).placeholder, "[photo]")
        XCTAssertEqual(ChatMedia(kind: .voice).placeholder, "[voice message]")
        XCTAssertEqual(ChatMedia(kind: .file, name: "plan.pdf").placeholder, "[document: plan.pdf]")
        XCTAssertEqual(ChatMedia(kind: .file, name: "").placeholder, "[document]")
    }
}
