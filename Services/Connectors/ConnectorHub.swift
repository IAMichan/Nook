import Foundation

/// Central hub for all integrations: refreshes in the background at respective intervals,
/// providing the brain with unified context and read tools for active sources. Queries never block on network:
/// context is read directly from cache.
@MainActor
final class ConnectorHub: ObservableObject {
    /// Increments after each refresh so UI knows new data is available.
    @Published private(set) var revision = 0

    private(set) var sources: [ContextSource] = []
    private var lastRefresh: [String: Date] = [:]
    private var running: Set<String> = []
    private var timer: Timer?

    func register(_ list: [ContextSource]) {
        for source in list where !sources.contains(where: { $0.id == source.id }) {
            sources.append(source)
        }
    }

    func source(id: String) -> ContextSource? {
        sources.first { $0.id == id }
    }

    var active: [ContextSource] { sources.filter { $0.isActive } }

    /// Where the model can look: everything active, plus sources whose tools can run without a cache.
    var searchable: [ContextSource] { sources.filter { $0.isActive || $0.canLookUp } }

    /// Integrations with pending user actions (failing CI, overdue reminder, etc.).
    var needingAttention: [ContextSource] { active.filter { $0.status.needsAttention } }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func tick() {
        let now = Date()
        for source in active where !running.contains(source.id) {
            let last = lastRefresh[source.id] ?? .distantPast
            if now.timeIntervalSince(last) >= source.refreshInterval {
                refresh(source)
            }
        }
    }

    /// Refreshes a single source (e.g. after saving a key).
    func refresh(_ source: ContextSource) {
        guard !running.contains(source.id) else { return }
        running.insert(source.id)
        lastRefresh[source.id] = Date()
        Task { [weak self] in
            await source.refresh()
            guard let self else { return }
            self.running.remove(source.id)
            self.revision += 1
        }
    }

    func refreshAll() {
        for source in sources { refresh(source) }
    }

    /// All active sources as brief context lines for the brain.
    func contextLines() -> [String] {
        var lines: [String] = []
        for source in active {
            let part = source.contextLines()
            guard !part.isEmpty else { continue }
            lines.append(contentsOf: part)
        }
        if let coverage = agendaCoverageLine { lines.append(coverage) }
        return lines
    }

    /// Context for a single query: excluded sources are omitted, relevant sources included in full,
    /// and remaining sources listed as a single line with their read tools. This prevents prompt bloat.
    /// `full` nil = everything in full (as used by notch cards).
    func contextLines(scope: SourceScope, full: Set<String>?) -> (lines: [String], fullTitles: [String]) {
        var lines: [String] = []
        var fullTitles: [String] = []
        var brief: [String] = []
        for source in searchable where scope.allows(source.id) {
            let part = source.contextLines()
            // Nothing cached (Mail still closed): at least add the line with the tools, so the model knows it can look.
            if (full?.contains(source.id) ?? true), !part.isEmpty {
                lines.append(contentsOf: part)
                fullTitles.append(source.title)
            } else {
                let readTools = source.tools.filter { $0.kind == .read }.map(\.name)
                var line = "- \(source.title)"
                if source.isActive, !source.status.headline.isEmpty { line += ": \(source.status.headline)" }
                if !readTools.isEmpty { line += " (read directly with \(readTools.joined(separator: ", ")))" }
                brief.append(line)
            }
        }
        if !brief.isEmpty {
            lines.append("Also connected, not included in full (query with the tool if relevant):")
            lines.append(contentsOf: brief)
        }
        if scope.allows("calendar"), let coverage = agendaCoverageLine { lines.append(coverage) }
        return (lines, fullTitles)
    }

    /// Which sources currently contribute to context, for the "I checked..." header above an answer.
    var contributingTitles: [String] {
        active.filter { !$0.contextLines().isEmpty }.map { $0.title }
    }

    var tools: [ToolSpec] { hubTools + searchable.flatMap { $0.tools } }
}
