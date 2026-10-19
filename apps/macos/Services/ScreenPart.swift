import AppKit
import Carbon.HIToolbox
import SwiftUI

// A part of the screen, after ⌥⌘4: ask Nook about it, paste it where you were (⌃V in a terminal, so Claude Code takes
// the image), copy it, or mark it up first with arrows, boxes and a pen.
//
// The paste and the annotation window are adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md).

enum ScreenPartPaste {
    /// Terminals take an image with ⌃V (Claude Code reads the clipboard itself), other apps with ⌘V.
    static func isTerminal(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return TerminalLauncher.knownTerminals.prefix(7).contains(id)
    }

    @MainActor static func put(png: Data, image: NSImage?) {
        let board = NSPasteboard.general
        board.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.png]
        let tiff = image?.tiffRepresentation
        if tiff != nil { types.append(.tiff) }
        board.declareTypes(types, owner: nil)
        board.setData(png, forType: .png)
        if let tiff { board.setData(tiff, forType: .tiff) }
    }

    /// Puts the image on the clipboard, brings `app` forward and sends the paste keys. False without Accessibility
    /// (the image then stays on the clipboard). The clipboard gets back what it held a moment later.
    @MainActor static func paste(png: Data, image: NSImage?, into app: NSRunningApplication?) async -> Bool {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var out: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { out[type] = data } }
            return out
        }
        put(png: png, image: image)
        guard AXIsProcessTrusted() else { return false }
        _ = app?.activate()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let source = CGEventSource(stateID: .combinedSessionState)
        let terminal = isTerminal(app)
        let key = terminal ? CGKeyCode(kVK_ANSI_V) : FlowPaste.vKeyCode()
        let flags: CGEventFlags = terminal ? .maskControl : .maskCommand
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        // Claude Code in a terminal reads the clipboard a little later: give it time, then put back what was there.
        let count = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard board.changeCount == count else { return }
            board.clearContents()
            guard !saved.isEmpty else { return }
            board.writeObjects(saved.map { entry in
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            })
        }
        return true
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// The annotation window: opens over everything, gives the marked-up image back.
@MainActor
final class ScreenPartAnnotator {
    static let shared = ScreenPartAnnotator()
    private var window: NSWindow?

    func annotate(_ image: NSImage, done: @escaping (NSImage?) -> Void) {
        window?.close()
        let view = CaptureAnnotationView(image: image) { [weak self] result in
            self?.window?.close()
            self?.window = nil
            done(result)
        }
        let maxW: CGFloat = 1100, maxH: CGFloat = 720
        let size = image.size
        let scale = min(1, min(maxW / max(1, size.width), maxH / max(1, size.height)))
        let content = NSSize(width: max(420, size.width * scale), height: size.height * scale + 56)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: content),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = tr("capture.annotate")
        win.titlebarAppearsTransparent = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: view)
        win.level = .floating
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

/// Arrows, boxes and a pen over the capture, then Done.
struct CaptureAnnotationView: View {
    let image: NSImage
    let onDone: @MainActor (NSImage?) -> Void

    enum Tool: CaseIterable { case arrow, box, pen }

    struct Mark {
        var tool: Tool
        var color: Int
        /// In the image's own proportions: (0, 0) top left, (1, 1) bottom right.
        var points: [CGPoint]
    }

    static let colors: [NSColor] = [
        NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1),
        NSColor(red: 1, green: 0.8, blue: 0.0, alpha: 1),
        NSColor(red: 0.23, green: 0.62, blue: 1, alpha: 1),
        NSColor.white,
    ]

    @State private var marks: [Mark] = []
    @State private var drawing: Mark? = nil
    @State private var tool: Tool = .arrow
    @State private var color = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                let fit = Self.fitted(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                    Canvas { ctx, size in
                        for mark in marks + (drawing.map { [$0] } ?? []) {
                            Self.draw(mark, in: &ctx, size: size, lineWidth: 3)
                        }
                    }
                    .frame(width: fit.width, height: fit.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let p = CGPoint(x: min(1, max(0, g.location.x / fit.width)),
                                            y: min(1, max(0, g.location.y / fit.height)))
                            if drawing == nil {
                                drawing = Mark(tool: tool, color: color, points: [p, p])
                            } else if tool == .pen {
                                drawing?.points.append(p)
                            } else {
                                drawing?.points[1] = p
                            }
                        }
                        .onEnded { _ in
                            if let mark = drawing { marks.append(mark) }
                            drawing = nil
                        })
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(Array(Tool.allCases.enumerated()), id: \.offset) { _, t in
                Button { tool = t } label: {
                    Image(systemName: t == .arrow ? "arrow.up.right" : (t == .box ? "rectangle" : "pencil.tip"))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(tool == t ? 0.16 : 0.05)))
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 18)
            ForEach(0..<Self.colors.count, id: \.self) { i in
                Button { color = i } label: {
                    Circle()
                        .fill(Color(nsColor: Self.colors[i]))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white.opacity(color == i ? 0.9 : 0), lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 18)
            Button { if !marks.isEmpty { marks.removeLast() } } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(marks.isEmpty)
            Spacer()
            Button(tr("button.cancel")) { onDone(nil) }
                .keyboardShortcut(.cancelAction)
            Button(tr("capture.done")) { onDone(render()) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(NookTheme.iris)
        }
        .foregroundColor(Color(white: 0.96))
        .padding(.leading, 82)      // clear of the window's buttons
        .padding(.trailing, 14)
        .frame(height: 56)
    }

    static func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let s = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * s, height: image.height * s)
    }

    /// One mark, in a canvas of `size` (y down).
    static func draw(_ mark: Mark, in ctx: inout GraphicsContext, size: CGSize, lineWidth: CGFloat) {
        let pts = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first, let last = pts.last else { return }
        let shading = GraphicsContext.Shading.color(Color(nsColor: colors[mark.color]))
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        switch mark.tool {
        case .pen:
            var p = Path()
            p.addLines(pts)
            ctx.stroke(p, with: shading, style: style)
        case .box:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: lineWidth * 1.5), with: shading, style: style)
        case .arrow:
            ctx.stroke(arrow(from: first, to: last, head: lineWidth * 5), with: shading, style: style)
        }
    }

    static func arrow(from a: CGPoint, to b: CGPoint, head: CGFloat) -> Path {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        guard hypot(b.x - a.x, b.y - a.y) > head * 0.5 else { return p }
        for side in [-1.0, 1.0] as [CGFloat] {
            let wing = angle + .pi + side * .pi / 7
            p.move(to: b)
            p.addLine(to: CGPoint(x: b.x + cos(wing) * head, y: b.y + sin(wing) * head))
        }
        return p
    }

    /// The capture with its marks, at the capture's full size.
    @MainActor private func render() -> NSImage? {
        guard !marks.isEmpty else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        let marks = self.marks
        let view = Canvas { ctx, s in
            ctx.draw(Image(decorative: cg, scale: 1), in: CGRect(origin: .zero, size: s))
            for mark in marks {
                Self.draw(mark, in: &ctx, size: s, lineWidth: max(3, s.width / 300))
            }
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let out = renderer.cgImage else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }
}
