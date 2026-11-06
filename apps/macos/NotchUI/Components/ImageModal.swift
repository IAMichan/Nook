import SwiftUI
import AppKit

/// The one way a picture is shown big, for a picture in a composer, in a message to an agent or to Nook, and in a chat with
/// any linked app: the picture at once, then sharp from the file on this Mac, as large as the room lets it, also past its
/// own pixels, so even a small picture can really be seen. A pinch or ⌘-scroll zooms in further, a drag moves it. A click
/// shrinks a zoomed picture back, and otherwise (or Escape) closes it; the open button shows it in Quick Look. While it is
/// open, the keys stay out of the field behind it, so Return never sends the message you are looking at a picture of.
///
/// It goes on the `ChatMediaStage` (`fills`), over the window or panel; use `ImageModalButton` to open it. A notch card
/// has no stage and shows it over itself.
struct ImageModal: View {
    let url: URL
    let preview: NSImage
    let name: String
    /// Over the whole window or panel, with room around the picture, rather than as a rounded sheet over a card.
    var fills = false
    let onClose: () -> Void
    let onOpen: () -> Void
    @State private var sharp: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(fills ? 0.85 : 0.94)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            ZoomablePhoto(image: sharp ?? preview,
                          pixels: ChatMediaImages.pixelSize(url) ?? preview.size,
                          onClick: onClose)
                .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous))
                .padding(fills ? NookTheme.Spacing.xxl : NookTheme.Spacing.sm)
                .help(tr("chat.photo.zoomHint"))
                .accessibilityElement()
                .accessibilityLabel(name)
                .accessibilityAddTraits(.isImage)
                .contextMenu {
                    Button(tr("chat.copyImage")) { Pasteboard.copyImage(url, fallback: sharp ?? preview) }
                    Button(tr("card.attachment.open"), action: onOpen)
                }

            HStack(spacing: 6) {
                zoomButton("arrow.up.forward.app", label: tr("card.attachment.open"), action: onOpen)
                zoomButton("xmark", label: tr("button.close"), action: onClose)
            }
            .padding(fills ? NookTheme.Spacing.md : 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: fills ? 0 : NookTheme.Radius.sheet, style: .continuous))
        // Before the focused field: a composer behind the modal would take Escape for itself and Return to send.
        .onWindowKeyDown { event in
            let plain = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            if event.keyCode == 53, plain { onClose() }
            return !event.modifierFlags.contains(.command)
        }
        .task(id: url) {
            let url = self.url
            // Read and decoded off the main thread: decoding a large photo at this size held up the zoom.
            sharp = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url)).flatMap { WhatsAppLink.thumbnail($0, side: 2400) }
            }.value
        }
    }

    private func zoomButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Anything that shows a picture small and opens it in the `ImageModal` on a click, with Enlarge and Open in its right-click
/// menu. Where a view has no stage (a notch card) the picture opens in Quick Look in a window of its own
/// (`FilePreviewWindow`). A click stays with a button laid over it, such as a composer's remove cross.
struct ImageModalButton<Label: View>: View {
    let name: String
    /// What shows until the sharp picture is read; nil while there is nothing to enlarge yet.
    let preview: NSImage?
    /// The picture as a file on this Mac, asked for when it opens.
    let file: () -> URL?
    @ViewBuilder let label: () -> Label
    @Environment(\.chatMediaStage) private var stage
    @State private var hovering = false

    var body: some View {
        Button(action: show) {
            label()
                .opacity(hovering && preview != nil ? 0.85 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(preview == nil)
        .onHover { hovering = $0 }
        .contextMenu {
            if preview != nil {
                Button(action: show) {
                    SwiftUI.Label(tr("card.video.enlarge"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button(action: openInQuickLook) {
                    SwiftUI.Label(tr("card.attachment.open"), systemImage: "arrow.up.forward.app")
                }
            }
        }
        .help(preview == nil ? name : tr("card.video.enlarge"))
        .accessibilityLabel(preview == nil ? name : "\(tr("card.video.enlarge")): \(name)")
    }

    private func show() {
        guard let preview, let url = file() else { return }
        if let stage {
            stage.show(photo: url, preview: preview, name: name, open: openInQuickLook)
        } else {
            openInQuickLook()
        }
    }

    private func openInQuickLook() {
        guard let url = file() else { return }
        if !FilePreviewWindow.shared.show(url, title: name) { NSWorkspace.shared.open(url) }
    }
}

/// A photo that zooms like Preview: a pinch or ⌘-scroll zooms in around the pointer, scrolling or a drag moves the
/// zoomed photo, a click shrinks it back to its first size and, at that size, calls `onClick`. It is drawn again at
/// every zoom from the photo itself, so it stays as sharp as the photo is.
private struct ZoomablePhoto: NSViewRepresentable {
    let image: NSImage
    /// The photo's own size in pixels, for its shape.
    let pixels: CGSize
    let onClick: () -> Void

    static let maxZoom: CGFloat = 8

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.update(image: image, pixels: pixels, onClick: onClick)
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.update(image: image, pixels: pixels, onClick: onClick)
    }

    /// The opening size: as large as fits in `room`, whatever the photo's own size.
    static func fittedSize(pixels: CGSize, in room: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, room.width > 0, room.height > 0 else { return room }
        let scale = min(room.width / pixels.width, room.height / pixels.height)
        return CGSize(width: max(1, (pixels.width * scale).rounded()), height: max(1, (pixels.height * scale).rounded()))
    }

    final class ZoomScrollView: NSScrollView {
        private let photo = PhotoCanvas()
        private var pixels: CGSize = .zero
        private var onClick: () -> Void = {}
        private var dragStart: NSPoint?
        private var dragged = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            let clip = CenteringClipView()
            clip.drawsBackground = false
            contentView = clip
            drawsBackground = false
            hasVerticalScroller = false
            hasHorizontalScroller = false
            borderType = .noBorder
            allowsMagnification = true
            minMagnification = 1
            maxMagnification = ZoomablePhoto.maxZoom
            documentView = photo
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(image: NSImage, pixels: CGSize, onClick: @escaping () -> Void) {
            self.onClick = onClick
            if photo.image !== image {
                photo.image = image
                photo.needsDisplay = true
            }
            guard self.pixels != pixels else { return }
            self.pixels = pixels
            fitPhoto()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fitPhoto()
        }

        /// The photo at its opening size for the room there is now; a zoom stays as it is.
        private func fitPhoto() {
            let size = ZoomablePhoto.fittedSize(pixels: pixels, in: bounds.size)
            guard photo.frame.size != size else { return }
            photo.setFrameSize(size)
            contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
            reflectScrolledClipView(contentView)
        }

        // Every click and drag on the photo or beside it lands here.
        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            let zoom = min(maxMagnification, max(minMagnification, magnification * exp(event.scrollingDeltaY * step)))
            setMagnification(zoom, centeredAt: contentView.convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = event.locationInWindow
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let point = event.locationInWindow
            if !dragged, hypot(point.x - start.x, point.y - start.y) < 3 { return }
            dragged = true
            // The photo follows the pointer: the visible part moves the other way, in the photo's own points.
            var origin = contentView.bounds.origin
            origin.x -= (point.x - start.x) / magnification
            origin.y -= (point.y - start.y) / magnification
            dragStart = point
            contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
            reflectScrolledClipView(contentView)
        }

        override func mouseUp(with event: NSEvent) {
            defer { dragStart = nil }
            guard !dragged else { return }
            if magnification > 1.01 {
                animator().magnification = 1
            } else {
                onClick()
            }
        }
    }

    /// Draws the photo over its whole frame, from the photo itself at the resolution the zoom asks for.
    final class PhotoCanvas: NSView {
        var image: NSImage?

        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.current?.imageInterpolation = .high
            image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// Keeps a photo smaller than the room in the middle, where a scroll view would put it in its corner.
    final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            guard let document = documentView else { return rect }
            if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
            if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
            return rect
        }
    }
}
