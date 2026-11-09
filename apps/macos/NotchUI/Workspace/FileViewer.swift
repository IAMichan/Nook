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

/// Edits to a text file in Nook's file viewer, kept apart from the view: switching tabs or opening another file keeps
/// what you typed, until you save it or stop editing.
@MainActor
final class FileEditor: ObservableObject {
    let path: String
    /// The file as it was opened to edit (and last saved); nil while it is only read.
    @Published private(set) var file: FileEditText?
    @Published var draft = ""

    init(path: String) { self.path = path }

    var editing: Bool { file != nil }
    var unsaved: Bool { file.map { $0.text != draft } ?? false }

    /// Starts editing: reads the file's text, or says why it cannot be edited.
    func begin() async {
        let path = path
        guard let loaded = await Task.detached(priority: .userInitiated, operation: { FileViewing.editable(path: path) }).value else {
            ToastCenter.shared.error(tr("file.viewer.cantEdit"), detail: AgentPathFormat.tilde(path))
            return
        }
        file = loaded
        draft = loaded.text
    }

    /// Writes the draft to the file (⌘S). A file someone else wrote since it was opened is only overwritten after you
    /// confirm it. True when it was saved.
    @discardableResult
    func save() -> Bool {
        guard let file else { return false }
        var result = FileViewing.save(draft, as: file, to: path)
        if result == .changedOnDisk {
            let alert = NSAlert()
            alert.messageText = tr("file.viewer.changedOnDisk")
            alert.informativeText = tr("file.viewer.changedOnDisk.detail", (path as NSString).lastPathComponent)
            alert.addButton(withTitle: tr("file.viewer.overwrite"))
            alert.addButton(withTitle: tr("button.cancel"))
            guard alert.runAboveNotch() == .alertFirstButtonReturn else { return false }
            result = FileViewing.save(draft, as: file, to: path, overwrite: true)
        }
        switch result {
        case .saved(let modified):
            self.file?.text = draft
            self.file?.modified = modified
            ToastCenter.shared.success(tr("file.viewer.saved"), detail: (path as NSString).lastPathComponent)
            return true
        case .failed(let reason):
            ToastCenter.shared.error(tr("file.viewer.saveFailed"), detail: reason)
            return false
        case .changedOnDisk:
            return false
        }
    }

    /// Back to reading; changes that were not saved are thrown away after you confirm it.
    func end() {
        if unsaved {
            let alert = NSAlert()
            alert.messageText = tr("file.viewer.discard")
            alert.informativeText = tr("file.viewer.discard.detail", (path as NSString).lastPathComponent)
            alert.addButton(withTitle: tr("file.viewer.discard.confirm"))
            alert.addButton(withTitle: tr("button.cancel"))
            guard alert.runAboveNotch() == .alertFirstButtonReturn else { return }
        }
        file = nil
        draft = ""
    }

    private static var open: [String: FileEditor] = [:]

    /// The one editor of a file, so the side panel and the window share what you typed.
    static func shared(_ path: String) -> FileEditor {
        if let editor = open[path] { return editor }
        let editor = FileEditor(path: path)
        open[path] = editor
        return editor
    }
}

/// A file read in Nook, the way an editor shows it: line numbers in a gutter, syntax colors (`SyntaxTokenizer`), and
/// the link's line in view and marked. Markdown can flip to how it reads; a picture, a PDF or another file that is not
/// text shows through Quick Look. A text file can be edited in place and saved with ⌘S (a `.env`, a config), without
/// opening another editor. The bar on top opens another file, opens it in your editor at the same line, shows it in
/// Finder, or copies its path. Nothing in it runs the file.
struct FileViewer: View {
    let target: FileTarget
    /// Changes on every open: scroll to the link's line again.
    var opened = UUID()
    /// In a session's side panel: links in a Markdown preview open beside the session too.
    var beside = false
    /// Where "Open file…" starts: the session's folder; else the file's own folder.
    var directory = ""
    /// Opens a file picked with "Open file…" in place of this one.
    var openOther: (FileTarget) -> Void = { _ in }
    @ObservedObject private var editor: FileEditor
    @State private var content: FileViewContent?
    @State private var reloads = 0
    @State private var markdownPreview = false
    /// A page an agent showed (`RenderedPage`) shows as the page, sandboxed as in the conversation; its source on request.
    @State private var pageSource = false
    @Environment(\.sessionContextTarget) private var session
    /// The line you are writing a remark about, and the remark.
    @State private var commentLine: Int?
    @State private var commentNote = ""

    init(target: FileTarget, opened: UUID = UUID(), beside: Bool = false, directory: String = "",
         openOther: @escaping (FileTarget) -> Void = { _ in }) {
        self.target = target
        self.opened = opened
        self.beside = beside
        self.directory = directory
        self.openOther = openOther
        _editor = ObservedObject(wrappedValue: FileEditor.shared(target.path))
    }

    private var name: String { (target.path as NSString).lastPathComponent }
    private var folder: String { (target.path as NSString).deletingLastPathComponent }
    private var isMarkdown: Bool { SyntaxLanguage.detect(path: target.path) == .markdown }
    /// A notebook reads as a document, with its source one click away like a Markdown file's.
    private var isNotebook: Bool { (target.path as NSString).pathExtension.lowercased() == "ipynb" }
    /// A diagram's source; its picture is one click away.
    private var isMermaid: Bool { ["mmd", "mermaid"].contains((target.path as NSString).pathExtension.lowercased()) }
    /// A page from an agent's conversation: only from the folder Nook keeps them in, never any HTML file.
    private var isPage: Bool { RenderedPage.isOwnFile(target.path, base: NookPaths.supportDirectory) }

    private func commentBar(_ line: Int, lines: [String]) -> some View {
        let send = {
            guard let session, !commentNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ComposerInbox.shared.add(SessionPrompts.fileLine(path: target.path, line: line, code: lines[line - 1], note: commentNote), to: session)
            commentLine = nil
            commentNote = ""
        }
        return HStack(spacing: NookTheme.Spacing.sm) {
            Text(tr("file.viewer.line", line)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            TextField(tr("file.viewer.comment"), text: $commentNote)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.paper)
                .onSubmit(send)
            ToolbarIconButton("arrow.up.circle", tr("session.context.add"), send)
            SidePanelCloseButton(help: tr("button.cancel")) { commentLine = nil }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .frame(height: SidePanelMetrics.toolbar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            NookDivider()
            Group {
                switch content {
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let lines, let tokens):
                    if editor.editing {
                        FileTextEditor(text: $editor.draft, onSave: { if editor.save() { reloads += 1 } })
                    } else if isPage && !pageSource {
                        SandboxedPageView(html: lines.joined(separator: "\n"))
                    } else if isMermaid && markdownPreview {
                        CodeRenderView(language: "mermaid", code: lines.joined(separator: "\n"))
                    } else if (isMarkdown || isNotebook) && markdownPreview {
                        ScrollView(.vertical) {
                            let source = lines.joined(separator: "\n")
                            MarkdownView(text: isNotebook ? (NotebookDocument.markdown(from: source) ?? source) : source)
                                .environment(\.fileLinkBase, folder)
                                .environment(\.pullRequestLinksBeside, beside)
                                .padding(NookTheme.Spacing.xl)
                        }
                    } else {
                        FileCodeView(lines: lines, tokens: tokens, line: FileViewing.clampedLine(target.line, count: lines.count),
                                     scrollKey: opened, comment: session == nil ? nil : { commentLine = $0 })
                            .equatable()
                        if let commentLine, commentLine <= lines.count { commentBar(commentLine, lines: lines) }
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
            if editor.editing {
                editActions
            } else {
                if isPage, case .text = content {
                    ToolbarIconButton(pageSource ? "eye" : "chevron.left.forwardslash.chevron.right",
                                      pageSource ? tr("code.preview") : tr("code.source")) { pageSource.toggle() }
                } else if isMarkdown || isNotebook || isMermaid, case .text = content {
                    ToolbarIconButton(markdownPreview ? "chevron.left.forwardslash.chevron.right" : "eye",
                                      markdownPreview ? tr("code.source") : tr("code.preview")) { markdownPreview.toggle() }
                }
                if case .text = content, !isPage {
                    ToolbarIconButton("pencil", tr("file.viewer.edit")) { Task { await editor.begin() } }
                }
                ToolbarIconButton("arrow.clockwise", tr("file.viewer.reload")) { reloads += 1 }
            }
            ToolbarIconButton("doc.badge.ellipsis", tr("file.viewer.open")) { pickFile() }
            CopyIconButton(tr("file.viewer.copyPath")) { target.path }
            ToolbarIconButton("folder", tr("file.viewer.reveal")) { AppModel.shared.workspace.revealInFinder(target.path) }
            ToolbarIconButton("arrow.up.forward.app", tr("file.viewer.openEditor")) { AppModel.shared.workspace.openFile(target) }
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .frame(height: SidePanelMetrics.toolbar)
        .background(NookTheme.canvas)
    }

    /// While editing: whether there is something to save, Save (⌘S in the text), and Done to go back to reading.
    @ViewBuilder private var editActions: some View {
        if editor.unsaved {
            Circle().fill(NookTheme.amber).frame(width: 6, height: 6)
            Text(tr("file.viewer.unsaved"))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
        }
        ToolbarIconButton("square.and.arrow.down", tr("file.viewer.save"), enabled: editor.unsaved) {
            if editor.save() { reloads += 1 }
        }
        ToolbarIconButton("checkmark", tr("file.viewer.done")) {
            editor.end()
            reloads += 1
        }
    }

    private func pickFile() {
        if let picked = FilePicker.pick(in: directory.isEmpty ? folder : directory) { openOther(picked) }
    }
}

/// "Open file…": any file to read or edit in the viewer, hidden ones such as `.env` included.
@MainActor
enum FilePicker {
    static func pick(in directory: String) -> FileTarget? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if !directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return nil }
        return FileTarget(path: url.path)
    }
}

/// The text of a file to edit: plain, in the code font, with undo and none of the system's smart quotes, dashes or
/// replacements, which would quietly change a key or a value. ⌘S saves.
private struct FileTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let textView = SavingTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let color = NSColor(NookTheme.textStrong)
        textView.font = font
        textView.textColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
        textView.insertionPointColor = NSColor(NookTheme.paper)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: NookTheme.Spacing.md, height: NookTheme.Spacing.sm)
        textView.string = text
        textView.delegate = context.coordinator
        textView.onSave = onSave
        scroll.documentView = textView
        if context.environment.sidePanelTakesFocus {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SavingTextView else { return }
        textView.onSave = onSave
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    /// Takes ⌘S while you type, before the notch or a window could.
    final class SavingTextView: NSTextView {
        var onSave: () -> Void = {}

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
                onSave()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// The lines of a text file with their numbers. Only the rows in view are built, so a long file opens at once; long
/// lines wrap, as in the diffs.
private struct FileCodeView: View, Equatable {
    let lines: [String]
    let tokens: [[SyntaxToken]]
    /// The link's line (1-based): scrolled to and marked.
    let line: Int?
    let scrollKey: UUID
    /// Starts a remark on a line (1-based), from the + on its number. Nil outside a session.
    var comment: ((Int) -> Void)? = nil
    /// The lines already in their colors, by index with what they were made from, so scrolling back over a line does
    /// not build it again.
    @State private var styledLines = StyledLines()

    private final class StyledLines {
        var byIndex: [Int: (text: String, tokens: [SyntaxToken], styled: AttributedString)] = [:]
    }

    /// Drawn again only when the file, its colors or the marked line changed (with `.equatable()` where it is used).
    nonisolated static func == (a: FileCodeView, b: FileCodeView) -> Bool {
        a.line == b.line && a.scrollKey == b.scrollKey && a.lines == b.lines && a.tokens == b.tokens
            && (a.comment == nil) == (b.comment == nil)
    }

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
            FileLineNumber(number: index + 1, marked: marked, comment: comment)
                .frame(width: numberWidth, alignment: .trailing)
                .padding(.top, 1)
            Text(styled(index))
                .font(NookTheme.mono(13))
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
        let found = index < tokens.count ? tokens[index] : []
        guard !found.isEmpty else { return AttributedString(text) }
        if let hit = styledLines.byIndex[index], hit.text == text, hit.tokens == found { return hit.styled }
        let units = Array(text.utf16)
        var result = AttributedString()
        for segment in DiffSyntax.segments(length: units.count, tokens: found, changed: nil) {
            var part = AttributedString(String(decoding: units[segment.start..<segment.end], as: UTF16.self))
            if let kind = segment.kind { part.foregroundColor = DiffSyntaxStyle.color(kind) }
            result += part
        }
        styledLines.byIndex[index] = (text, found, result)
        return result
    }
}

/// A line's number; with the pointer on it, the + that starts a remark on that line.
private struct FileLineNumber: View {
    let number: Int
    let marked: Bool
    let comment: ((Int) -> Void)?
    @State private var hovering = false

    var body: some View {
        Group {
            if hovering, let comment {
                Button { comment(number) } label: {
                    Image(systemName: "plus.bubble").font(NookTheme.mono(10.5)).foregroundStyle(NookTheme.paper)
                }
                .buttonStyle(.plain)
                .help(tr("file.viewer.comment"))
                .accessibilityLabel(tr("file.viewer.comment"))
            } else {
                Text(verbatim: String(number))
                    .font(NookTheme.mono(10.5))
                    .foregroundStyle(marked ? NookTheme.paper : WS.tertiary)
            }
        }
        .padding(.trailing, NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A file Quick Look shows (a picture, a PDF, a document), inside the viewer.
struct QuickLookView: NSViewRepresentable {
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

/// The File tab of a session's side panel: the file a link in the conversation opened, or one picked with "Open file…".
struct SessionFilePanel: View {
    /// The session's folder, where "Open file…" starts.
    var directory = ""
    @ObservedObject private var store = FileViewerStore.shared

    var body: some View {
        if let target = store.target {
            FileViewer(target: target, opened: store.opened, beside: true, directory: directory) { store.open($0) }
                .id(target.path)
        } else {
            WSEmptyState(symbol: "doc.text", title: tr("agents.tool.file.emptyTitle"), message: tr("agents.tool.file.emptyMessage"),
                         action: (tr("file.viewer.open"), { if let picked = FilePicker.pick(in: directory) { store.open(picked) } }))
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
        window.contentView = NSHostingView(rootView: FileViewer(target: target, opened: UUID()) { [weak self] in self?.show($0) }
            .id(target.path))
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
