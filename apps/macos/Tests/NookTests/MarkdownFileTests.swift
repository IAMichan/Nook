import XCTest

/// A README in the file preview reads as GitHub draws it: badges side by side, wrapped lines as one paragraph, layout
/// HTML gone and a `<picture>` as its dark image.
final class MarkdownFileTests: XCTestCase {
    func testImagesOnConsecutiveLinesFormOneRow() {
        let text = "![Bun](https://img.shields.io/a.svg)\n![Go](https://img.shields.io/b.svg) [![CI](https://x.dev/c.svg)](https://x.dev/ci)\n\nNext"
        let blocks = MarkdownBlock.parse(text)
        guard case .images(let images) = blocks.first else { return XCTFail("no row: \(blocks)") }
        XCTAssertEqual(images.map(\.alt), ["Bun", "Go", "CI"])
        XCTAssertEqual(images[2].source, "https://x.dev/c.svg")
        XCTAssertEqual(images[2].link, "https://x.dev/ci")
        XCTAssertNil(images[0].link)
        XCTAssertEqual(blocks.count, 2)
        // A link that does not open a web page leaves the picture without one.
        XCTAssertEqual(MarkdownBlock.parse("[![A](a.svg)](javascript:x)").first, .image(alt: "A", source: "a.svg"))
    }

    func testMarkdownFileReadsAsGitHubDoes() {
        let readme = """
        <div align="center">

        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="brand/dark.svg">
          <img src="brand/paper.svg" alt="Infaris" width="360">
        </picture>

        One repo for
        everything.

        [Start](#start) ·
        [Docs](#docs)

        </div>

        - item that
          wraps over
          three lines
        - other

        > [!NOTE]
        > A note that
        > wraps.

        ```
        keep
        these
        ```
        """
        let document = MarkdownBlock.fileDocument(readme)
        let blocks = MarkdownBlock.parse(document)
        XCTAssertFalse(document.contains("<div"))
        XCTAssertTrue(blocks.contains(.image(alt: "Infaris", source: "brand/dark.svg")), "\(blocks)")
        XCTAssertTrue(blocks.contains(.paragraph("One repo for everything.")), "\(blocks)")
        XCTAssertTrue(blocks.contains(.paragraph("[Start](#start) · [Docs](#docs)")), "\(blocks)")
        XCTAssertTrue(blocks.contains(.code(language: "", code: "keep\nthese", title: nil)))
        XCTAssertTrue(blocks.contains(.list([MarkdownListItem(level: 0, number: nil, text: "item that wraps over three lines"),
                                             MarkdownListItem(level: 0, number: nil, text: "other")])), "\(blocks)")
        XCTAssertTrue(blocks.contains(.quote("[!NOTE]\nA note that wraps.")), "\(blocks)")
        XCTAssertEqual(MarkdownBlock.fileDocument(#"<a href="https://x.dev"><img src="https://x.dev/b.svg" alt="B"></a>"#)
            .trimmingCharacters(in: .whitespacesAndNewlines), "[![B](https://x.dev/b.svg)](https://x.dev)")
    }
}
