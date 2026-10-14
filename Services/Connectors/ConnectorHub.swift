import Foundation

/// Alle koppelingen op één plek: ververst ze op de achtergrond, elk in zijn eigen tempo, en geeft het brein
/// in één keer de context en de lees-tools van alles wat aan staat. Een vraag wacht nooit op netwerk: de context komt uit de cache.
@MainActor
final class ConnectorHub: ObservableObject {
    /// Gaat omhoog na elke verversing, zodat de UI weet dat er iets nieuws is.
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

    /// Koppelingen waar iets op jou wacht (falende CI, herinnering te laat…).
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

    /// Ververst één bron (bijvoorbeeld na het opslaan van een sleutel).
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

    /// Alles wat aan staat, als korte regels voor het brein.
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

    /// Welke bronnen er nu iets aan de context bijdragen, voor het "Ik keek in…"-regeltje boven een antwoord.
    var contributingTitles: [String] {
        active.filter { !$0.contextLines().isEmpty }.map { $0.title }
    }

    var tools: [ToolSpec] { hubTools + active.flatMap { $0.tools } }
}
