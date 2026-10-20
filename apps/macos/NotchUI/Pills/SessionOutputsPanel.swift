import SwiftUI
import AppKit
import WebKit

/// Next to a session's conversation: what the agent produced (see SessionOutputs). Its task list, the plans it
/// proposed, and the designs, documents and images it wrote, each shown the way it is meant to be seen: a page as it
/// renders, Markdown formatted, an image as the image.
struct SessionOutputsPanel: View {
    let outputs: [SessionOutput]
    @Binding var selection: String?
    @Binding var wide: Bool
    let close: () -> Void

    private var current: SessionOutput? {
        outputs.first { $0.id == selection } ?? outputs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if outputs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("ws.outputs.empty.title")).font(NookTheme.font(12.5, .medium)).foregroundStyle(NookTheme.textSecondary)
                    Text(tr("ws.outputs.empty.body"))
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                Spacer(minLength: 0)
            } else {
                if outputs.count > 1 { list }
                if let current {
                    ToolSurface { OutputViewer(output: current).id(current.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full").font(.system(size: 11, weight: .semibold)).foregroundStyle(NookTheme.textTertiary)
            Text(tr("ws.outputs.title")).font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
            if !outputs.isEmpty {
                Text("\(outputs.count)").font(NookTheme.mono(11, .medium)).foregroundStyle(NookTheme.textTertiary)
            }
            Spacer(minLength: 4)
            ToolbarIconButton(wide ? "arrow.right.to.line" : "arrow.left.to.line", tr(wide ? "ws.outputs.narrow" : "ws.outputs.widen")) {
                withAnimation(.easeInOut(duration: 0.2)) { wide.toggle() }
            }
            ToolbarIconButton("xmark", tr("ws.outputs.close"), close)
        }
        .frame(height: 30)
    }

    /// One row per output, newest first; the list scrolls when it is long.
    private var list: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(outputs) { output in
                    let chosen = output.id == current?.id
                    Button { selection = output.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: OutputText.symbol(output.kind))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(chosen ? NookTheme.paper : NookTheme.textTertiary)
                                .frame(width: 16)
                            Text(OutputText.title(output)).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(chosen ? NookTheme.paper : NookTheme.textSecondary)
                            Spacer(minLength: 6)
                            Text(OutputText.kind(output.kind)).foregroundStyle(NookTheme.textTertiary)
                        }
                        .font(NookTheme.font(12))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chosen ? NookTheme.smoke : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(output.path ?? OutputText.title(output))
                }
            }
        }
        .frame(maxHeight: min(CGFloat(outputs.count) * 28, 148))
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
            Rectangle().fill(NookTheme.line2.opacity(0.6)).frame(height: 1)
            actions
        }
    }

    @ViewBuilder
    private var content: some View {
        switch output.kind {
        case .tasks(let steps):
            ScrollView { TaskListRows(steps: steps).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        case .plan(let text):
            ScrollView { MarkdownView(text: text, size: 12.5).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        case .design:
            if let path = output.path {
                // Written again: the page loads again.
                LocalPageView(url: URL(fileURLWithPath: path)).id(output.date)
            }
        case .document:
            if let path = output.path { DocumentPreview(path: path, version: output.date) }
        case .image:
            if let path = output.path, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(10)
            } else {
                missing
            }
        }
    }

    private var missing: some View {
        Text(tr("ws.outputs.missing")).font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary).padding(14)
    }

    private var actions: some View {
        HStack(spacing: 6) {
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
        VStack(alignment: .leading, spacing: 8) {
            header
            ToolSurface {
                VStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(NookTheme.line2.opacity(0.6)).frame(height: 1)
                    actions
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold)).foregroundStyle(NookTheme.textTertiary)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(AgentPathFormat.tilde(path))
            Spacer(minLength: 4)
            ToolbarIconButton(wide ? "arrow.right.to.line" : "arrow.left.to.line", tr(wide ? "ws.outputs.narrow" : "ws.outputs.widen")) {
                withAnimation(.easeInOut(duration: 0.2)) { wide.toggle() }
            }
            ToolbarIconButton("xmark", tr("ws.outputs.close"), close)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        switch SessionOutputs.kind(path: path) {
        case .document?:
            DocumentPreview(path: path, version: opened)
        case .image?:
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(10)
            } else {
                FileTextPreview(path: path)
            }
        default:
            FileTextPreview(path: path)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
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
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                note(tr("ws.outputs.missing"))
            case .binary:
                note(tr("ws.file.binary"))
            case .text(let lines):
                ScrollView([.vertical, .horizontal]) {
                    let digits = String(lines.count).count
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 12) {
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
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: path) {
            let path = self.path
            loaded = await Task.detached(priority: .utility) { () -> Loaded in
                guard let data = FileManager.default.contents(atPath: path) else { return .missing }
                let head = data.prefix(400_000)
                if head.prefix(8_000).contains(0) { return .binary }
                return .text(String(decoding: head, as: UTF8.self).components(separatedBy: "\n"))
            }.value
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.font(12))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                if let text { MarkdownView(text: text, size: 12.5) } else { ProgressView().controlSize(.small) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: path + "@" + String(version.timeIntervalSince1970)) {
            let path = self.path
            let read = await Task.detached(priority: .utility) { () -> String? in
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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                TaskStepRow(step: step)
            }
        }
    }
}

/// The button in a session's header that opens or closes the outputs panel: a quiet group of its own next to the
/// side panel's tools, with how many outputs there are while the panel is closed and a dot when something is new.
struct SessionOutputsButton: View {
    let open: Bool
    var count = 0
    var fresh = false
    var tint: Color = NookTheme.iris
    let toggle: () -> Void

    var body: some View {
        let showCount = !open && count > 0
        let label = fresh ? tr("ws.outputs.title") + " · " + tr("ws.outputs.new") : tr("ws.outputs.title")
        Button { withAnimation(.easeInOut(duration: 0.2)) { toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "tray.full").font(.system(size: 11, weight: .medium))
                if showCount { Text("\(count)").font(NookTheme.mono(10.5, .medium)) }
            }
            .foregroundStyle(open ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, showCount ? 7 : 0)
            .frame(height: ToolbarGroup.itemHeight)
            .frame(minWidth: 26)
            .background(RoundedRectangle(cornerRadius: ToolbarGroup.itemRadius, style: .continuous).fill(open ? NookTheme.smoke : Color.clear))
            .overlay(alignment: .topTrailing) {
                if fresh { Circle().fill(tint).frame(width: 5, height: 5).offset(x: -3, y: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolbarGroup()
        .help(open || fresh ? label : tr("ws.outputs.show"))
        .accessibilityLabel(label)
    }
}
