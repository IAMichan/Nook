import AppKit
import PDFKit
import SwiftUI

/// A PDF beside a session that you can point at, as an element in the browser: over a page the pointer is a crosshair,
/// and a click marks the spot and hands it to the session's composer as a snippet (the page, how far the spot is from
/// every edge, the text there) with a picture of the area around it. Scrolling and zooming work as in any PDF view.
struct PdfPointView: NSViewRepresentable {
    let url: URL
    let session: SessionContextTarget

    func makeNSView(context: Context) -> PdfPointContainer {
        let view = PdfPointContainer()
        view.onPick = pick
        view.load(url)
        return view
    }

    func updateNSView(_ view: PdfPointContainer, context: Context) {
        view.onPick = pick
        if view.url != url { view.load(url) }
    }

    private func pick(_ point: PickedPdfPoint, _ picture: NSImage?) {
        let image = picture.flatMap { ImageAttachment(image: $0, name: point.imageName) }
        ComposerInbox.shared.add(pdfPoint: point, image: image, to: session)
    }
}

/// The PDF view with a layer on top that takes the pointer: the crosshair and the clicks are its own, scrolling and
/// zooming go on to the PDF.
final class PdfPointContainer: NSView {
    private(set) var url: URL?
    var onPick: (PickedPdfPoint, NSImage?) -> Void = { _, _ in }
    private let pdfView = PDFView()
    private let overlay = PdfPointOverlay()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .clear
        for view in [pdfView, overlay] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        overlay.pdfView = pdfView
        overlay.onClick = { [weak self] page, location in self?.pick(page, at: location) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func load(_ url: URL) {
        self.url = url
        pdfView.document = PDFDocument(url: url)
    }

    private func pick(_ page: PDFPage, at location: CGPoint) {
        guard let document = pdfView.document, let path = url?.path else { return }
        let point = PdfPointCapture.point(on: page, at: location, in: document, path: path)
        let picture = PdfPointCapture.picture(of: page, around: point)
        page.addAnnotation(PdfPointCapture.mark(at: location))
        onPick(point, picture)
    }
}

/// Over a page: a crosshair, and a click is a pick. Between pages and beside them the arrow stays.
final class PdfPointOverlay: NSView {
    weak var pdfView: PDFView?
    var onClick: (PDFPage, CGPoint) -> Void = { _, _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// The page under the pointer and the spot on it, in the page's own space.
    private func spot(_ event: NSEvent) -> (page: PDFPage, location: CGPoint)? {
        guard let pdfView else { return nil }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inView, nearest: false) else { return nil }
        let location = pdfView.convert(inView, to: page)
        guard page.bounds(for: .cropBox).contains(location) else { return nil }
        return (page, location)
    }

    private func updateCursor(_ event: NSEvent) {
        (spot(event) == nil ? NSCursor.arrow : NSCursor.crosshair).set()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func mouseEntered(with event: NSEvent) { updateCursor(event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        guard let found = spot(event) else { return }
        onClick(found.page, found.location)
    }

    override func scrollWheel(with event: NSEvent) { pdfView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { pdfView?.smartMagnify(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
