import SwiftUI
import AppKit
import WebKit

/// The outputs tab in a session's side (or bottom) panel: what the agent produced (see SessionOutputs). Its task list,
/// the plans it proposed, and the designs, documents and images it wrote, each shown the way it is meant to be seen: a
/// page as it renders, Markdown formatted, an image as the image. The panel's tab bar is its header.
struct SessionOutputsPanel: View {
    let outputs: [SessionOutput]
    @Binding var selection: String?

    private var current: SessionOutput? {
        outputs.first { $0.id == selection } ?? outputs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if outputs.isEmpty {
                WSEmptyState(symbol: SessionTool.outputs.symbol, title: tr("ws.outputs.empty.title"),
                             message: tr("ws.outputs.empty.body"))
            } else if let current {
                ToolSurface {
                    VStack(spacing: 0) {
                        if outputs.count > 1 {
                            OutputTabStrip(outputs: outputs, current: current.id) { selection = $0 }
                            NookDivider()
                        }
                        OutputViewer(output: current).id(current.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The outputs side by side as tabs, newest first, on top of the surface that shows the chosen one. They belong to
/// that surface, not to the side panel's tab bar above it: they sit inside it, on its own fill, and the chosen one is
/// underlined instead of filled, so the two rows of tabs never read as one. The strip scrolls sideways when they do
/// not fit.
private struct OutputTabStrip: View {
    let outputs: [SessionOutput]
    let current: String
    let select: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(outputs) { output in
                        OutputTab(output: output, chosen: output.id == current) { select(output.id) }
                            .id(output.id)
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.sm)
            }
            .onChange(of: current) { _, id in
                withAnimation(NookTheme.scroll) { proxy.scrollTo(id) }
            }
        }
        .frame(height: 32)
    }
}

/// One output in `OutputTabStrip`: its mark and title, the chosen one bright with a line under it.
private struct OutputTab: View {
    let output: SessionOutput
    let chosen: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: OutputText.symbol(output.kind))
                    .font(NookTheme.font(10.5, .medium))
                    .foregroundStyle(chosen ? NookTheme.paper : NookTheme.textTertiary)
                Text(OutputText.title(output))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(chosen || hovering ? NookTheme.paper : NookTheme.textSecondary)
            }
            .font(chosen ? NookTheme.TextStyle.label : NookTheme.TextStyle.detail)
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(chosen ? NookTheme.iris : Color.clear)
                    .frame(height: 2)
                    .padding(.horizontal, NookTheme.Spacing.sm)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(OutputText.kind(output.kind) + " · " + (output.path ?? OutputText.title(output)))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The words and icons of an output.
enum OutputText {
    static func title(_ output: SessionOutput) -> String {
        switch output.kind {
        case .tasks: return tr("ws.tasks.title")
        case .plan: return output.title.isEmpty ? tr("ws.plan.title") : output.title
        default: return output.title
        }
    }

    static func kind(_ kind: SessionOutput.Kind) -> String {
        switch kind {
        case .tasks(let steps):
            let progress = RunTasks.progress(steps)
            return tr("ws.checklist.progress", progress.done, progress.total)
        case .plan: return tr("ws.outputs.kind.plan")
        case .design: return tr("ws.outputs.kind.design")
        case .document: return tr("ws.outputs.kind.document")
        case .image: return tr("ws.outputs.kind.image")
        }
    }

    static func symbol(_ kind: SessionOutput.Kind) -> String {
        switch kind {
        case .tasks: return "checklist"
        case .plan: return "list.bullet.clipboard"
        case .design: return "paintbrush.pointed"
        case .document: return "doc.richtext"
        case .image: return "photo"
        }
    }
}

/// One output, shown as what it is, with what you can do with it underneath.
private struct OutputViewer: View {
    let output: SessionOutput
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            NookDivider()
            actions
        }
    }

    @ViewBuilder
    private var content: some View {
        switch output.kind {
        case .tasks(let steps):
            ScrollView { TaskListRows(steps: steps).padding(NookTheme.Spacing.xl).frame(maxWidth: .infinity, alignment: .leading) }
        case .plan(let text):
            ScrollView { MarkdownView(text: text, size: 13.5).padding(NookTheme.Spacing.xl).frame(maxWidth: .infinity, alignment: .leading) }
        case .design:
            if let path = output.path {
                // Written again: the page loads again.
                LocalPageView(url: URL(fileURLWithPath: path)).id(output.date)
            }
        case .document:
            if let path = output.path { DocumentPreview(path: path, version: output.date) }
        case .image:
            if let path = output.path, let image = PreviewImages.image(path, version: output.date) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(10)
            } else {
                missing
            }
        }
    }

    private var missing: some View {
        Text(tr("ws.outputs.missing")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).padding(14)
    }

    private var actions: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let path = output.path {
                Text(AgentPathFormat.tilde(path))
                    .font(NookTheme.mono(10.5))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                SmallGhostButton(title: tr("ws.outputs.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                SmallGhostButton(title: tr("ws.outputs.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            } else {
                Spacer(minLength: 6)
                SmallGhostButton(title: copied ? tr("ws.outputs.copied") : tr("ws.plan.copy")) {
                    Pasteboard.copy(Self.text(output.kind))
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    /// A plan as its Markdown; a task list as a Markdown checklist.
    private static func text(_ kind: SessionOutput.Kind) -> String {
        switch kind {
        case .plan(let text): return text
        case .tasks(let steps): return steps.map { ($0.status == .done ? "- [x] " : "- [ ] ") + $0.text }.joined(separator: "\n")
        default: return ""
        }
    }
}

/// A file the agent read or wrote, opened from its step in the conversation: Markdown formatted, a picture as itself,
/// anything else as its text with line numbers. It is read when it opens, as it is on disk now.
struct FilePreviewPanel: View {
    let path: String
    @Binding var wide: Bool
    let close: () -> Void
    /// Fixed while the panel shows this file: the Markdown preview reads it once.
    @State private var opened = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            header
            ToolSurface {
                VStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    NookDivider()
                    actions
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The side panel's own header (`SidePanelHeader`), on the right of the conversation.
    private var header: some View {
        SidePanelHeader(closeHelp: tr("ws.outputs.close"), wide: $wide, close: close) {
            SidePanelTitle(symbol: "doc.text", title: URL(fileURLWithPath: path).lastPathComponent,
                           help: AgentPathFormat.tilde(path))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch SessionOutputs.kind(path: path) {
        case .document?:
            DocumentPreview(path: path, version: opened)
        case .image?:
            if let image = PreviewImages.image(path, version: opened) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(10)
            } else {
                FileTextPreview(path: path)
            }
        default:
            FileTextPreview(path: path)
        }
    }

    private var actions: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(AgentPathFormat.tilde(path))
                .font(NookTheme.mono(10.5))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            SmallGhostButton(title: tr("ws.outputs.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            SmallGhostButton(title: tr("ws.outputs.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }
}

/// A file as plain text with line numbers, selectable. A very long one shows its start; a binary file says so.
private struct FileTextPreview: View {
    private enum Loaded: Sendable { case text([String]), binary, missing }

    let path: String
    @State private var loaded: Loaded?

    var body: some View {
        Group {
            switch loaded {
            case nil:
                PatientSpinner()
            case .missing:
                note(tr("ws.outputs.missing"))
            case .binary:
                note(tr("ws.file.binary"))
            case .text(let lines):
                ScrollView([.vertical, .horizontal]) {
                    let digits = String(lines.count).count
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
                                Text(String(index + 1))
                                    .foregroundStyle(NookTheme.textTertiary)
                                    .frame(width: CGFloat(digits) * 7.5, alignment: .trailing)
                                Text(line.isEmpty ? " " : line)
                                    .foregroundStyle(NookTheme.textSecondary)
                                    .fixedSize()
                            }
                        }
                    }
                    .font(NookTheme.mono(11.5))
                    .textSelection(.enabled)
                    .padding(NookTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: path) {
            let path = self.path
            loaded = await Task.detached(priority: .userInitiated) { () -> Loaded in
                guard let data = FileManager.default.contents(atPath: path) else { return .missing }
                let head = data.prefix(400_000)
                if head.prefix(8_000).contains(0) { return .binary }
                return .text(String(decoding: head, as: UTF8.self).components(separatedBy: "\n"))
            }.value
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Pictures the outputs and the file preview show, read once per file and version: the panel redraws while the
/// conversation beside it streams or you type, and reading a large picture from disk on each redraw made that stutter.
private enum PreviewImages {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        return cache
    }()

    static func image(_ path: String, version: Date) -> NSImage? {
        let key = "\(path)@\(version.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A Markdown file the agent wrote, formatted. Read again when it is written again; a very long one shows its start.
private struct DocumentPreview: View {
    let path: String
    let version: Date
    @State private var text: String?

    var body: some View {
        ScrollView {
            Group {
                if let text { MarkdownView(text: text, size: 13.5) } else { PatientSpinner() }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: path + "@" + String(version.timeIntervalSince1970)) {
            let path = self.path
            let read = await Task.detached(priority: .userInitiated) { () -> String? in
                FileManager.default.contents(atPath: path).map { String(decoding: $0.prefix(400_000), as: UTF8.self) }
            }.value
            text = read ?? tr("ws.outputs.missing")
        }
    }
}

/// A page or drawing from disk, as it renders. It may read the files next to it (its styles, scripts and images), and
/// stays where it is: a link you click opens in your browser, and nothing navigates it elsewhere by itself.
private struct LocalPageView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let target = navigationAction.request.url else { return .cancel }
            let scheme = target.scheme?.lowercased() ?? ""
            if target.isFileURL || ["about", "data", "blob"].contains(scheme) { return .allow }
            // Frames inside the page may load; only the page itself stays put.
            if navigationAction.targetFrame?.isMainFrame == false { return .allow }
            if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(scheme) {
                await MainActor.run { _ = NSWorkspace.shared.open(target) }
            }
            return .cancel
        }
    }
}

/// A task list as rows, without a card around it: the checklist card's rows, and the plan in a TodoWrite or
/// update_plan call that you open.
struct TaskListRows: View {
    let steps: [RunTaskStep]

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                TaskStepRow(step: step)
            }
        }
    }
}
