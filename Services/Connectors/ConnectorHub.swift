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

    /// Waar het brein in kan kijken: alles wat actief is, plus bronnen die hun tools ook zonder cache kunnen draaien.
    var searchable: [ContextSource] { sources.filter { $0.isActive || $0.canLookUp } }

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

    /// Context voor één vraag: bronnen die de gebruiker uitsloot gaan niet mee, relevante bronnen volledig, de rest als één regel
    /// met de tool waarmee het brein er gericht in kan kijken. Zo gaat niet bij elke vraag alles van elke bron naar het brein.
    /// `full` nil = alles volledig (zoals de kaarten in de notch het gebruiken).
    func contextLines(scope: SourceScope, full: Set<String>?) -> (lines: [String], fullTitles: [String]) {
        var lines: [String] = []
        var fullTitles: [String] = []
        var brief: [String] = []
        for source in searchable where scope.allows(source.id) {
            let part = source.contextLines()
            // Niets in de cache (Mail nog dicht): dan in elk geval de regel met de tools, zodat het brein weet dat hij kan kijken.
            if (full?.contains(source.id) ?? true), !part.isEmpty {
                lines.append(contentsOf: part)
                fullTitles.append(source.title)
            } else {
                let readTools = source.tools.filter { $0.kind == .read }.map(\.name)
                var line = "- \(source.title)"
                if source.isActive, !source.status.headline.isEmpty { line += ": \(source.status.headline)" }
                if !readTools.isEmpty { line += " (lees gericht met \(readTools.joined(separator: ", ")))" }
                brief.append(line)
            }
        }
        if !brief.isEmpty {
            lines.append("Ook gekoppeld, niet volledig meegestuurd (kijk erin met de tool als de vraag erom vraagt):")
            lines.append(contentsOf: brief)
        }
        if scope.allows("calendar"), let coverage = agendaCoverageLine { lines.append(coverage) }
        return (lines, fullTitles)
    }

    /// Welke bronnen er nu iets aan de context bijdragen, voor het "Ik keek in…"-regeltje boven een antwoord.
    var contributingTitles: [String] {
        active.filter { !$0.contextLines().isEmpty }.map { $0.title }
    }

    var tools: [ToolSpec] { hubTools + searchable.flatMap { $0.tools } }
}
