import AppKit
import Quartz
import SwiftUI

/// The file a link in an agent's conversation opened in the session's side panel (the File tab).
@MainActor
final class FileViewerStore: ObservableObject {
    static let shared = FileViewerStore()

    @Published private(set) var target: FileTarget?
    /// New on every open, so a link to the same file at another line scrolls there again.
    @Published private(set) var opened = UUID()

    func open(_ target: FileTarget) {
        self.target = target
        opened = UUID()
    }
}

/// A file read in Nook, the way an editor shows it: line numbers in a gutter, syntax colors (`SyntaxTokenizer`), and
/// the link's line in view and marked. Markdown can flip to how it reads; a picture, a PDF or another file that is not
/// text shows through Quick Look. The bar on top opens it in your editor at the same line, shows it in Finder, or
/// copies its path. Nothing in it runs the file.
struct FileViewer: View {
    let target: FileTarget
    /// Changes on every open: scroll to the link's line again.
    var opened = UUID()
    /// In a session's side panel: links in a Markdown preview open beside the session too.
    var beside = false
    @State private var content: FileViewContent?
    @State private var reloads = 0
    @State private var markdownPreview = false
    @State private var copied = false

    private var name: String { (target.path as NSString).lastPathComponent }
    private var folder: String { (target.path as NSString).deletingLastPathComponent }
    private var isMarkdown: Bool { SyntaxLanguage.detect(path: target.path) == .markdown }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            NookDivider()
            Group {
                switch content {
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let lines, let tokens):
                    if isMarkdown && markdownPreview {
                        ScrollView(.vertical) {
                            MarkdownView(text: lines.joined(separator: "\n"))
                                .environment(\.fileLinkBase, folder)
                                .environment(\.pullRequestLinksBeside, beside)
                                .padding(NookTheme.Spacing.xl)
                        }
                    } else {
                        FileCodeView(lines: lines, tokens: tokens, line: FileViewing.clampedLine(target.line, count: lines.count),
                                     scrollKey: opened)
                    }
                case .preview:
                    QuickLookView(url: URL(fileURLWithPath: target.path))
                case .folder, .missing:
                    Text(tr("ws.file.missing", AgentPathFormat.tilde(target.path)))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WS.code)
        .task(id: "\(target.path)|\(reloads)") {
            let path = target.path
            let loaded = await Task.detached(priority: .userInitiated) { FileViewing.load(path: path) }.value
            if !Task.isCancelled { content = loaded }
        }
    }

    /// The file's name and folder, then its actions.
    private var bar: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(systemName: content == .preview ? "doc" : "doc.text")
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
            Text(name)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
            if let line = target.line {
                Text(tr("file.viewer.line", line))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            Text(AgentPathFormat.tilde(folder))
                .font(NookTheme.mono(11))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(target.path)
            Spacer(minLength: NookTheme.Spacing.sm)
            if isMarkdown, case .text = content {
                ToolbarIconButton(markdownPreview ? "chevron.left.forwardslash.chevron.right" : "eye",
                                  markdownPreview ? tr("code.source") : tr("code.preview")) { markdownPreview.toggle() }
            }
            ToolbarIconButton("arrow.clockwise", tr("file.viewer.reload")) { reloads += 1 }
            ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", copied ? tr("button.copied") : tr("file.viewer.copyPath")) {
                Pasteboard.copy(target.path)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            ToolbarIconButton("folder", tr("file.viewer.reveal")) { AppModel.shared.workspace.revealInFinder(target.path) }
            ToolbarIconButton("arrow.up.forward.app", tr("file.viewer.openEditor")) { AppModel.shared.workspace.openFile(target) }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .frame(height: 34)
        .background(NookTheme.canvas)
    }
}

/// The lines of a text file with their numbers. Only the rows in view are built, so a long file opens at once; long
/// lines wrap, as in the diffs.
private struct FileCodeView: View {
    let lines: [String]
    let tokens: [[SyntaxToken]]
    /// The link's line (1-based): scrolled to and marked.
    let line: Int?
    let scrollKey: UUID

    private var numberWidth: CGFloat { CGFloat(max(String(lines.count).count, 2)) * 6.6 + 18 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        row(index).id(index)
                    }
                }
                .padding(.vertical, NookTheme.Spacing.sm)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: scrollKey) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let line else { return }
        // After the first layout, or the lazy stack has no row to scroll to yet.
        DispatchQueue.main.async { proxy.scrollTo(line - 1, anchor: .center) }
    }

    private func row(_ index: Int) -> some View {
        let marked = line == index + 1
        return HStack(alignment: .top, spacing: 0) {
            Text(verbatim: String(index + 1))
                .font(NookTheme.mono(10.5))
                .foregroundStyle(marked ? NookTheme.paper : WS.tertiary)
                .padding(.trailing, NookTheme.Spacing.md)
                .frame(width: numberWidth, alignment: .trailing)
                .padding(.top, 1)
            Text(styled(index))
                .font(NookTheme.mono(11.5))
                .foregroundStyle(NookTheme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, NookTheme.Spacing.xl)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1.5)
        .background(marked ? WS.selected : Color.clear)
        .overlay(alignment: .leading) {
            if marked { Rectangle().fill(NookTheme.amber).frame(width: 2) }
        }
    }

    /// The line in its syntax colors.
    private func styled(_ index: Int) -> AttributedString {
        let text = lines[index]
        guard !text.isEmpty else { return AttributedString(" ") }
        let units = Array(text.utf16)
        let found = index < tokens.count ? tokens[index] : []
        guard !found.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        for segment in DiffSyntax.segments(length: units.count, tokens: found, changed: nil) {
            var part = AttributedString(String(decoding: units[segment.start..<segment.end], as: UTF16.self))
            if let kind = segment.kind { part.foregroundColor = DiffSyntaxStyle.color(kind) }
            result += part
        }
        return result
    }
}

/// A file Quick Look shows (a picture, a PDF, a document), inside the viewer.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// The File tab of a session's side panel: the file a link in the conversation opened.
struct SessionFilePanel: View {
    @ObservedObject private var store = FileViewerStore.shared

    var body: some View {
        if let target = store.target {
            FileViewer(target: target, opened: store.opened, beside: true)
                .id(target.path)
                .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
        } else {
            Color.clear
        }
    }
}

/// A file link clicked outside an agent's session (a chat, a terminal): the same viewer in a window of its own.
@MainActor
final class FileViewerWindow: NSObject, NSWindowDelegate {
    static let shared = FileViewerWindow()

    private var window: NSWindow?

    func show(_ target: FileTarget) {
        let window = window ?? make()
        window.contentView = NSHostingView(rootView: FileViewer(target: target, opened: UUID()).id(target.path))
        window.title = (target.path as NSString).lastPathComponent
        window.representedURL = URL(fileURLWithPath: target.path)
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 360, height: 240)
        window.delegate = self
        self.window = window
        return window
    }

    /// A closed window lets go of the file.
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }
}
