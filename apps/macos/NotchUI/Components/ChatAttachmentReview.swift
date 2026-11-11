import SwiftUI
import AppKit

/// What was done to the pictures waiting to go, and how the preview stands: the file shown, the tool in use. It lives apart
/// from `ChatComposerModel` so a line drawn redraws the preview and not the whole open chat.
@MainActor
final class ChatAttachmentEdits: ObservableObject {
    enum Tool: Equatable {
        case crop, draw, text
    }

    @Published var tool: Tool?
    @Published var ink = ChatImageInk.red
    @Published private var selected: String?
    @Published private var edits: [String: ChatImageEdit] = [:]
    /// The steps back, per file.
    private var history: [String: [ChatImageEdit]] = [:]

    /// A picture Nook can draw on. An animated GIF would lose its movement, so that goes as it is.
    static func canEdit(_ file: ChatAttachment) -> Bool {
        file.kind != .gif && file.fileExtension != "gif" && ImageAttachment.isPicture(file.url)
    }

    /// The file the preview shows: the one picked, else the newest.
    func shown(in files: [ChatAttachment]) -> ChatAttachment? {
        files.first { $0.id == selected } ?? files.last
    }

    func select(_ id: String) {
        guard selected != id else { return }
        selected = id
        tool = nil
    }

    /// The file next to the one shown, one way or the other; false when there is none.
    @discardableResult func move(_ offset: Int, in files: [ChatAttachment]) -> Bool {
        guard let shown = shown(in: files), let next = files.id(offset, from: shown.id) else { return false }
        select(next)
        return true
    }

    /// The file shown is about to go: its neighbour stays in view, not the last one added.
    func removing(_ id: String, from files: [ChatAttachment]) {
        guard shown(in: files)?.id == id, let heir = files.heir(of: id) else { return }
        select(heir)
    }

    func edit(of id: String) -> ChatImageEdit {
        edits[id] ?? ChatImageEdit()
    }

    /// What is to be done to this file before it goes; nil when it can go as it is.
    func change(of file: ChatAttachment) -> ChatImageEdit? {
        edits[file.id].flatMap { $0.isUntouched ? nil : $0 }
    }

    func hasChanges(in files: [ChatAttachment]) -> Bool {
        files.contains { change(of: $0) != nil }
    }

    /// One step, which `undo` takes back.
    func apply(_ id: String, _ step: (inout ChatImageEdit) -> Void) {
        let before = edit(of: id)
        var after = before
        step(&after)
        guard after != before else { return }
        history[id, default: []].append(before)
        edits[id] = after
    }

    func canUndo(_ id: String) -> Bool {
        history[id]?.isEmpty == false
    }

    func undo(_ id: String) {
        guard let last = history[id]?.popLast() else { return }
        edits[id] = last
    }

    func forget(_ id: String) {
        edits[id] = nil
        history[id] = nil
    }

    func reset() {
        edits = [:]
        history = [:]
        selected = nil
        tool = nil
    }
}

/// A file about to go, big, over the chat, with the chat's own field under it for the words that go along: a picture to crop,
/// turn, draw and write on, and any other file as Quick Look shows it. Nothing is sent from here; the field's send button
/// or Return sends it, with what was done to it.
struct ChatAttachmentReview: View {
    @ObservedObject var model: ChatComposerModel
    @ObservedObject var edits: ChatAttachmentEdits
    let sends: Set<ChatOutgoing.Kind>
    /// The keyboard goes back to the field.
    let onDone: () -> Void

    @State private var label = ""
    @FocusState private var labelFocused: Bool

    private static let toolSize: CGFloat = 30

    var body: some View {
        if let file = edits.shown(in: model.files) {
            let editable = ChatAttachmentEdits.canEdit(file)
            VStack(spacing: 0) {
                header(file, editable: editable)
                if editable, let tool = edits.tool { options(tool, file: file) }
                Group {
                    if editable {
                        ChatImageCanvas(edits: edits, file: file)
                    } else {
                        QuickLookView(url: file.url)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(file.id)
            }
            .background(NookTheme.canvas)
            .contentShape(Rectangle())
        }
    }

    private func header(_ file: ChatAttachment, editable: Bool) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            // Several files go at once with this cross; one goes with the bin on its thumbnail.
            ToolbarIconButton("xmark", tr(model.files.count > 1 ? "chat.review.closeAll" : "chat.review.close"), height: Self.toolSize, width: Self.toolSize, symbolSize: 13) {
                withAnimation(NookTheme.reveal) { model.discardFiles() }
                onDone()
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(file.name)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: NookTheme.Spacing.xs) {
                    ChatAttachmentKindMenu(file: file, kinds: file.alternatives.filter { sends.contains(ChatOutgoing.Kind($0)) }) {
                        model.change(file.id, to: $0)
                    }
                    Text(ChatAttachment.size(file.bytes))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            if editable { tools(file) }
        }
        .padding(NookTheme.Spacing.sm)
    }

    @ViewBuilder private func tools(_ file: ChatAttachment) -> some View {
        ToolbarIconButton("arrow.uturn.backward", tr("chat.review.undo"), height: Self.toolSize, width: Self.toolSize,
                          enabled: edits.canUndo(file.id), symbolSize: 13) { edits.undo(file.id) }
        ToolbarIconButton("rotate.right", tr("chat.review.rotate"), height: Self.toolSize, width: Self.toolSize, symbolSize: 13) {
            edits.apply(file.id) { $0.rotate() }
        }
        tool(.crop, "crop", tr("chat.review.crop"))
        tool(.text, "textformat", tr("chat.review.text"))
        tool(.draw, "pencil", tr("chat.review.draw"))
    }

    private func tool(_ tool: ChatAttachmentEdits.Tool, _ symbol: String, _ title: String) -> some View {
        ToolbarIconButton(symbol, title, height: Self.toolSize, width: Self.toolSize, selected: edits.tool == tool, symbolSize: 13) {
            leaveTool(for: edits.tool == tool ? nil : tool)
        }
    }

    private func leaveTool(for next: ChatAttachmentEdits.Tool?) {
        edits.tool = next
        labelFocused = next == .text
        if next != .text { label = "" }
        if next == nil { onDone() }
    }

    /// What goes with the tool in use, under the header.
    @ViewBuilder private func options(_ tool: ChatAttachmentEdits.Tool, file: ChatAttachment) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if tool == .draw || tool == .text {
                ForEach(ChatImageInk.allCases, id: \.self) { ink in
                    ChatInkButton(ink: ink, selected: edits.ink == ink) { edits.ink = ink }
                }
            }
            if tool == .text {
                TextField(tr("chat.review.text.placeholder"), text: $label)
                    .textFieldStyle(.plain)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .focused($labelFocused)
                    .onSubmit { addLabel(to: file) }
                    .onExitCommand { leaveTool(for: nil) }
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .frame(height: 26)
                    .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
                    .onAppear { labelFocused = true }
            } else {
                Spacer(minLength: 0)
            }
            SmallGhostButton(title: tr("chat.review.done")) {
                if tool == .text { addLabel(to: file) } else { leaveTool(for: nil) }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.bottom, NookTheme.Spacing.sm)
    }

    /// The text lands in the middle of what shows, to be dragged where it belongs.
    private func addLabel(to file: ChatAttachment) {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let ink = edits.ink
            edits.apply(file.id) { edit in
                edit.labels.append(.init(text: text, center: CGPoint(x: edit.crop.midX, y: edit.crop.midY), ink: ink))
            }
        }
        leaveTool(for: nil)
    }
}

/// One color to draw or write with.
private struct ChatInkButton: View {
    let ink: ChatImageInk
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(cgColor: ink.cgColor))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(NookTheme.textTertiary, lineWidth: 1))
                .padding(NookTheme.Spacing.xxs)
                .overlay(Circle().strokeBorder(selected ? NookTheme.paper : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.nookPlain)
        .help(tr("chat.review.ink." + ink.rawValue))
        .accessibilityLabel(tr("chat.review.ink." + ink.rawValue))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The picture as it will go. While the crop tool is in use it shows whole, with the frame over it; else only what stays.
private struct ChatImageCanvas: View {
    @ObservedObject var edits: ChatAttachmentEdits
    let file: ChatAttachment

    private struct Loaded: Hashable {
        var path: String
        var turns: Int
    }

    private static let space = "chat-image"
    /// Sharp on a big window; the file's own pixels are for what is sent.
    nonisolated private static let previewSide = 2400

    @State private var picture: NSImage?
    @State private var line: [CGPoint] = []
    @State private var movingLabel: UUID?
    @State private var labelMove: CGSize = .zero
    @State private var cropping: CGRect?
    @State private var cropStart: CGRect?

    var body: some View {
        let edit = edits.edit(of: file.id)
        GeometryReader { room in
            if let picture {
                stage(picture, edit: edit, room: room.size)
                    .position(x: room.size.width / 2, y: room.size.height / 2)
            }
        }
        .padding([.horizontal, .bottom], NookTheme.Spacing.md)
        .task(id: Loaded(path: file.path, turns: edit.turns)) {
            let url = file.url
            let turned = ChatImageEdit(turns: edit.turns)
            picture = await Task.detached(priority: .userInitiated) {
                let source = ChatImageRender.picture(url, side: Self.previewSide)
                return source.flatMap { ChatImageRender.render($0, edit: turned) }
                    .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }.value
        }
    }

    private func stage(_ picture: NSImage, edit: ChatImageEdit, room: CGSize) -> some View {
        let cropTool = edits.tool == .crop
        let window = cropTool ? ChatImageEdit.whole : edit.crop
        let scale = min(room.width / max(1, picture.size.width * window.width),
                        room.height / max(1, picture.size.height * window.height))
        let full = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
        let shown = CGSize(width: full.width * window.width, height: full.height * window.height)
        return layers(picture, edit: edit, full: full)
            .offset(x: -window.minX * full.width, y: -window.minY * full.height)
            .frame(width: shown.width, height: shown.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(edits.tool == .draw ? drawing(in: window, shown: shown) : nil)
            .overlay {
                if cropTool {
                    ChatCropFrame(crop: cropping ?? edit.crop, size: shown, space: Self.space) { handle, delta in
                        let start = cropStart ?? edit.crop
                        cropStart = start
                        cropping = ChatImageEdit.crop(start, moving: handle, by: delta)
                    } onEnd: {
                        if let cropping { edits.apply(file.id) { $0.crop = cropping } }
                        cropping = nil
                        cropStart = nil
                    }
                }
            }
            .coordinateSpace(name: Self.space)
    }

    private func layers(_ picture: NSImage, edit: ChatImageEdit, full: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .frame(width: full.width, height: full.height)
            let ink = edits.ink
            Canvas { context, _ in
                for stroke in edit.strokes { Self.draw(stroke.points, stroke.ink, in: context, full: full) }
                Self.draw(line, ink, in: context, full: full)
            }
            .frame(width: full.width, height: full.height)
            .allowsHitTesting(false)
            ForEach(edit.labels) { label in
                labelView(label, full: full)
            }
        }
        .frame(width: full.width, height: full.height, alignment: .topLeading)
    }

    /// Text moves with a drag, unless a line or the crop frame is what the pointer is for.
    private func labelView(_ label: ChatImageEdit.Label, full: CGSize) -> some View {
        let moving = movingLabel == label.id
        return Text(label.text)
            .font(NookTheme.font(max(full.width, full.height) * ChatImageEdit.labelSize, .semibold))
            .foregroundStyle(Color(cgColor: label.ink.cgColor))
            .fixedSize()
            .position(x: label.center.x * full.width + (moving ? labelMove.width : 0),
                      y: label.center.y * full.height + (moving ? labelMove.height : 0))
            .gesture(DragGesture(coordinateSpace: .named(Self.space))
                .onChanged { value in
                    movingLabel = label.id
                    labelMove = value.translation
                }
                .onEnded { value in
                    let center = ChatImageEdit.clamped(CGPoint(x: label.center.x + value.translation.width / full.width,
                                                               y: label.center.y + value.translation.height / full.height))
                    edits.apply(file.id) { edit in
                        guard let index = edit.labels.firstIndex(where: { $0.id == label.id }) else { return }
                        edit.labels[index].center = center
                    }
                    movingLabel = nil
                    labelMove = .zero
                })
            .allowsHitTesting(edits.tool == nil || edits.tool == .text)
    }

    private func drawing(in window: CGRect, shown: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                line.append(ChatImageEdit.point(CGPoint(x: value.location.x / shown.width, y: value.location.y / shown.height),
                                                in: window))
            }
            .onEnded { _ in
                let points = line
                let ink = edits.ink
                line = []
                edits.apply(file.id) { $0.strokes.append(.init(points: points, ink: ink)) }
            }
    }

    private static func draw(_ points: [CGPoint], _ ink: ChatImageInk, in context: GraphicsContext, full: CGSize) {
        guard let first = points.first else { return }
        var path = Path()
        path.addLines(([first] + points).map { CGPoint(x: $0.x * full.width, y: $0.y * full.height) })
        let width = max(full.width, full.height) * ChatImageEdit.strokeWidth
        context.stroke(path, with: .color(Color(cgColor: ink.cgColor)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// The frame of the crop tool over the whole picture: what goes is dimmed, the corners and edges pull, the inside moves it.
private struct ChatCropFrame: View {
    let crop: CGRect
    let size: CGSize
    let space: String
    let onDrag: (ChatImageEdit.CropHandle, CGSize) -> Void
    let onEnd: () -> Void

    private static let grip: CGFloat = 18
    private static let mark: CGFloat = 10

    private var frame: CGRect {
        CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width, height: crop.height * size.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(frame)
            }
            .fill(NookTheme.canvas.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(NookTheme.paper, lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .position(x: frame.midX, y: frame.midY)
                .gesture(drag(.inside))
            ForEach(ChatImageEdit.CropHandle.allCases.filter { $0 != .inside }, id: \.self) { handle in
                Circle()
                    .fill(NookTheme.paper)
                    .frame(width: Self.mark, height: Self.mark)
                    .frame(width: Self.grip, height: Self.grip)
                    .contentShape(Rectangle())
                    .position(place(of: handle))
                    .gesture(drag(handle))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func place(of handle: ChatImageEdit.CropHandle) -> CGPoint {
        CGPoint(x: handle.movesLeft ? frame.minX : handle.movesRight ? frame.maxX : frame.midX,
                y: handle.movesTop ? frame.minY : handle.movesBottom ? frame.maxY : frame.midY)
    }

    private func drag(_ handle: ChatImageEdit.CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                onDrag(handle, CGSize(width: value.translation.width / size.width, height: value.translation.height / size.height))
            }
            .onEnded { _ in onEnd() }
    }
}
