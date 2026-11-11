import AppKit
import SwiftUI

// What the file viewer in the side panel adds to a file that is more than code (a page, a picture, a diagram, a document):
// live reload while the agent writes it, its versions with a diff between two and a way back, and the actions on it
// (copy, download, open in the browser). The kind of a file is `ArtifactKind`, its versions `ArtifactHistory`.

// MARK: Live reload

/// Calls `handler` once for each burst of writes to a file, on a background queue: the file changed, was replaced (an
/// editor or an agent that writes a new file and renames it over the old one) or was removed. A file that is not
/// there is not waited for; the watcher is stopped with `stop()`. It costs nothing while the file does not change.
final class FileChangeWatcher: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "nook.file-change-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stopped = false
    /// Tries left to open a file that was just replaced: the new one appears a moment after the old one goes.
    private var retries = 10

    /// Writes that follow each other closer than this count as one.
    private static let quiet: TimeInterval = 0.3

    init(path: String, handler: @escaping @Sendable () -> Void) {
        self.path = path
        self.handler = handler
        queue.async { [self] in start() }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending?.cancel()
            source?.cancel()
            source = nil
        }
    }

    private func start() {
        guard !stopped else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            guard retries > 0 else { return }
            retries -= 1
            queue.asyncAfter(deadline: .now() + 0.2) { [self] in start() }
            return
        }
        retries = 10
        let watching = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                 eventMask: [.write, .extend, .delete, .rename], queue: queue)
        watching.setEventHandler { [self] in
            schedule()
            // The file under this name is another one now: watch the new one.
            if !watching.data.intersection([.delete, .rename]).isEmpty { watching.cancel() }
        }
        watching.setCancelHandler { [self] in
            close(descriptor)
            guard !stopped else { return }
            source = nil
            queue.asyncAfter(deadline: .now() + 0.2) { [self] in start() }
        }
        source = watching
        watching.resume()
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [handler] in handler() }
        pending = item
        queue.asyncAfter(deadline: .now() + Self.quiet, execute: item)
    }
}

// MARK: Versions

/// The versions of the files open in the panel, kept while Nook runs: a file the agent writes again and again keeps its
/// last versions (`ArtifactHistory`), so you can see what changed and go back. Large files are not kept.
@MainActor
final class ArtifactHistoryStore: ObservableObject {
    static let shared = ArtifactHistoryStore()

    /// Larger files are left out: thirty copies of one would weigh more than the panel is worth.
    static let largestText = 512 * 1024
    /// How many files keep their versions.
    private static let files = 12

    @Published private(set) var histories: [String: ArtifactHistory] = [:]
    private var order: [String] = []

    func history(_ path: String) -> ArtifactHistory { histories[path] ?? ArtifactHistory() }

    /// Makes `text` the latest version of the file when it differs from the one before.
    func record(_ text: String, path: String) {
        guard text.utf8.count <= Self.largestText else { return }
        var history = histories[path] ?? ArtifactHistory()
        guard history.record(text) else { return }
        histories[path] = history
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > Self.files { histories[order.removeFirst()] = nil }
    }

    /// Writes a version's text over the file, the way the file was written (its encoding and line breaks). True when done.
    static func restore(_ text: String, to path: String) -> Bool {
        let current = FileViewing.editable(path: path) ?? FileEditText(text: text)
        switch FileViewing.save(text, as: current, to: path, overwrite: true) {
        case .saved:
            return true
        case .failed(let reason):
            ToastCenter.shared.error(tr("artifact.version.restoreFailed"), detail: reason)
            return false
        case .changedOnDisk:
            return false
        }
    }
}

/// The file's versions, in the bar: the clock opens the list, newest first; the latest one is the file as it is now.
struct ArtifactVersionMenu: View {
    let history: ArtifactHistory
    /// The version in view; nil for the latest.
    let viewing: Int?
    let choose: (Int?) -> Void

    var body: some View {
        let latest = history.latest?.number
        ComposerDropdown(width: 220, scrolls: true) {
            Image(icon: "clock.arrow.circlepath")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(viewing == nil ? NookTheme.textSecondary : NookTheme.amber)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        } content: {
            ForEach(history.versions.reversed()) { version in
                DropdownRow(title: tr("artifact.version", version.number),
                            trailing: version.date.formatted(date: .omitted, time: .shortened),
                            chosen: (viewing ?? latest) == version.number) {
                    choose(version.number == latest ? nil : version.number)
                }
            }
        }
        .help(tr("artifact.versions"))
        .accessibilityLabel(tr("artifact.versions"))
    }
}

/// Under the file's bar while an older version is in view: which one, compare it with the one before, restore it, or go
/// back to the file as it is.
struct ArtifactVersionBar: View {
    let viewing: ArtifactVersion
    let latest: Int
    @Binding var comparing: Bool
    let restore: () -> Void
    let back: () -> Void

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(icon: "clock.arrow.circlepath")
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.amber)
            Text(tr("artifact.version.viewing", viewing.number, latest))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textStrong)
                .lineLimit(1)
            Text(viewing.date.formatted(date: .omitted, time: .shortened))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: NookTheme.Spacing.sm)
            ToolbarIconButton("plus.forwardslash.minus", tr("artifact.version.compare"), selected: comparing) { comparing.toggle() }
            ToolbarIconButton("arrow.uturn.backward", tr("artifact.version.restore"), restore)
            ToolbarIconButton("arrow.right.to.line", tr("artifact.version.latest"), back)
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .frame(height: SidePanelMetrics.toolbar)
        .background(NookTheme.canvas)
    }
}

/// The change from one version to the one before, in the diff viewer every other diff uses.
struct ArtifactVersionDiff: View {
    let old: String
    let new: String
    let name: String

    var body: some View {
        let diff = ArtifactHistory.unifiedDiff(from: old, to: new, name: name)
        if diff.isEmpty {
            Text(tr("artifact.version.same"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffText(text: diff, path: name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Live state

/// "Updating…" while the file is read again after a change on disk: a dot and a word, no spinner.
struct ArtifactUpdatingMark: View {
    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Circle().fill(NookTheme.iris).frame(width: 5, height: 5)
            Text(tr("artifact.updating"))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Actions

/// The rest of the file's actions behind one button: its text, a copy on disk, the page in the browser, another file, the
/// path, Finder, your editor.
struct ArtifactMoreMenu: View {
    let path: String
    let kind: ArtifactKind
    /// The text in view (a version, or the file as it is); nil for a picture or a PDF.
    let text: () -> String?
    let openFile: () -> Void
    let reveal: () -> Void
    let openEditor: () -> Void

    var body: some View {
        ComposerDropdown(width: 220) {
            Image(icon: "ellipsis")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        } content: {
            if kind.isText {
                DropdownRow(symbol: "doc.on.doc", title: tr("artifact.copyContents")) { copy(text() ?? "") }
            }
            DropdownRow(symbol: "link", title: tr("file.viewer.copyPath")) { copy(path) }
            DropdownRow(symbol: "arrow.down.to.line", title: tr("artifact.download")) { download() }
            if kind.rendersInSandbox {
                DropdownRow(symbol: "safari", title: tr("artifact.openBrowser")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            DropdownRow(symbol: "doc.badge.ellipsis", title: tr("file.viewer.open"), action: openFile)
            DropdownRow(symbol: "folder", title: tr("file.viewer.reveal"), action: reveal)
            DropdownRow(symbol: "arrow.up.forward.app", title: tr("file.viewer.openEditor"), action: openEditor)
        }
        .help(tr("artifact.more"))
        .accessibilityLabel(tr("artifact.more"))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        ToastCenter.shared.success(tr("button.copied"), detail: (path as NSString).lastPathComponent)
    }

    /// Saves what is in view under a name you choose: the text of a version, or a copy of the file.
    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runAboveNotch() == .OK, let destination = panel.url else { return }
        do {
            if kind.isText, let text = text() {
                try text.write(to: destination, atomically: true, encoding: .utf8)
            } else {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
            }
            ToastCenter.shared.success(tr("file.viewer.saved"), detail: destination.lastPathComponent)
        } catch {
            ToastCenter.shared.error(tr("file.viewer.saveFailed"), detail: error.localizedDescription)
        }
    }
}
