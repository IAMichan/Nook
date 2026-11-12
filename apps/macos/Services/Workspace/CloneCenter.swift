import Foundation

/// Clones that run in the background. "Clone repository…" in the new session composer hands the address here and the
/// box is free again at once: the clone shows as a quiet notice in the panel's top-right corner (`CloneNoticeStack`), with
/// how far git is, Hide and Cancel, while you go on with anything else. When it is done a toast says so with Open, which
/// opens the composer on the new project (the composer that started it picks it by itself while it still shows the
/// project it was on); when it fails the toast says why in git's words. Several clones can run side by side.
@MainActor
final class CloneCenter: ObservableObject {
    static let shared = CloneCenter()

    struct Job: Identifiable, Equatable {
        let id: UUID
        let url: String
        /// "owner/repo", as the notice names it.
        let name: String
        var progress: GitCloneProgress?
        /// Out of sight: it still runs, and the toast still comes when it is done.
        var hidden = false
        var cancelling = false
    }

    /// A clone that finished, for the composer that started it.
    struct Finished: Equatable {
        let id: UUID
        let path: String
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var finished: Finished?
    private var stops: [UUID: ProcessRunner.StopFlag] = [:]

    private init() {}

    /// The clones whose notice shows.
    var shown: [Job] { jobs.filter { !$0.hidden } }

    /// Starts cloning `url` into `parent`; nil when that address is being cloned already (its notice comes back).
    @discardableResult
    func start(url: String, parent: String, workspace: WorkspaceManager) -> UUID? {
        if let index = jobs.firstIndex(where: { $0.url == url }) {
            jobs[index].hidden = false
            return nil
        }
        let id = UUID()
        let stop = ProcessRunner.StopFlag()
        stops[id] = stop
        let name = GitCloneProgress.displayName(url)
        jobs.append(Job(id: id, url: url, name: name))
        Task {
            do {
                let result = try await workspace.clone(url: url, into: parent, progress: { progress in
                    Task { @MainActor in CloneCenter.shared.update(id, progress) }
                }, cancel: stop)
                finish(id)
                finished = Finished(id: id, path: result.path)
                let detail = [AgentPathFormat.tilde(result.path), result.usedHTTPS ? tr("sc.clone.usedHTTPS") : nil]
                    .compactMap { $0 }.joined(separator: "\n")
                ToastCenter.shared.success(tr("clone.done", name), detail: detail,
                                           action: NookToastAction(title: tr("clone.open")) { Self.open(result.path) })
            } catch is GitService.CloneCancelled {
                finish(id)
                ToastCenter.shared.info(tr("clone.cancelled", name))
            } catch {
                finish(id)
                ToastCenter.shared.error(error, title: tr("clone.failed", name))
            }
        }
        return id
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].cancelling else { return }
        jobs[index].cancelling = true
        stops[id]?.set()
    }

    func hide(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].hidden else { return }
        jobs[index].hidden = true
    }

    /// Opens the new session composer on the project, in the main window.
    static func open(_ path: String) {
        PromptLinkInbox.shared.requestProject(path)
        AppModel.shared.openWorkspace(newSession: true)
    }

    private func update(_ id: UUID, _ progress: GitCloneProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].progress != progress else { return }
        jobs[index].progress = progress
    }

    private func finish(_ id: UUID) {
        stops[id] = nil
        jobs.removeAll { $0.id == id }
    }
}
