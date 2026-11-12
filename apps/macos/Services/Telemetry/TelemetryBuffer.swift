import Foundation

/// What waits for Nook's next export, per signal: spans and log records in order (the oldest dropped past `limit`), sums
/// added up per name and attribute set. A signal whose receiver did not answer is paused for `pause` and what arrives
/// meanwhile is dropped, so a receiver that is down costs one failed request a minute, never a storm of retries.
/// A value type without clocks or I/O, so the tests drive it.
struct TelemetryBuffer: Sendable {
    var limit = 256
    var pause: TimeInterval = 60

    private(set) var spans: [OTLPSpan] = []
    private(set) var logs: [OTLPLogRecord] = []
    private(set) var sums: [OTLPSum] = []
    /// When the sums started adding up: the start of the metric points' interval.
    private(set) var sumsSince: Date?
    private(set) var pausedUntil: [OTLPSignal: Date] = [:]

    var isEmpty: Bool { spans.isEmpty && logs.isEmpty && sums.isEmpty }

    func isPaused(_ signal: OTLPSignal, now: Date) -> Bool {
        guard let until = pausedUntil[signal] else { return false }
        return now < until
    }

    mutating func add(_ span: OTLPSpan, now: Date) {
        guard !isPaused(.traces, now: now) else { return }
        spans.append(span)
        if spans.count > limit { spans.removeFirst(spans.count - limit) }
    }

    mutating func add(_ record: OTLPLogRecord, now: Date) {
        guard !isPaused(.logs, now: now) else { return }
        logs.append(record)
        if logs.count > limit { logs.removeFirst(logs.count - limit) }
    }

    mutating func add(_ sum: OTLPSum, now: Date) {
        guard !isPaused(.metrics, now: now) else { return }
        if let index = sums.firstIndex(where: { $0.name == sum.name && $0.attributes == sum.attributes }) {
            sums[index].value += sum.value
        } else if sums.count < limit {
            sums.append(sum)
        }
        if sumsSince == nil { sumsSince = now }
    }

    /// Everything waiting, taken out for one export.
    mutating func drain() -> (spans: [OTLPSpan], logs: [OTLPLogRecord], sums: [OTLPSum], sumsSince: Date?) {
        defer { spans = []; logs = []; sums = []; sumsSince = nil }
        return (spans, logs, sums, sumsSince)
    }

    /// The receiver of a signal did not take an export: that export is gone, and the signal rests for `pause`.
    mutating func failed(_ signal: OTLPSignal, now: Date) {
        pausedUntil[signal] = now.addingTimeInterval(pause)
    }

    mutating func succeeded(_ signal: OTLPSignal) {
        pausedUntil[signal] = nil
    }
}

/// The records Nook makes of what happened, apart from sending them, so the tests check what goes out.
enum TelemetryRecords {
    /// The records of one finished turn. Only counts and names: no prompt, answer, path or session id.
    static func turn(_ run: WorkspaceRun, started: Date, before: RunUsage, now: Date)
        -> (span: OTLPSpan, sums: [OTLPSum], log: OTLPLogRecord) {
        let outcome = run.status.rawValue
        var attributes: [String: OTLPValue] = [
            "nook.agent.provider": .string(run.provider.rawValue),
            "nook.agent.outcome": .string(outcome),
            "nook.agent.remote": .bool(run.remote != nil),
        ]
        if !run.model.isEmpty { attributes["nook.agent.model"] = .string(run.model) }
        let tokens: [(String, Int?, Int?)] = [
            ("input", run.usage.inputTokens, before.inputTokens),
            ("output", run.usage.outputTokens, before.outputTokens),
            ("cache_read", run.usage.cacheReadTokens, before.cacheReadTokens),
            ("cache_write", run.usage.cacheWriteTokens, before.cacheWriteTokens),
        ]
        var tokenSums: [OTLPSum] = []
        for (kind, after, earlier) in tokens {
            guard let after else { continue }
            let added = max(0, after - (earlier ?? 0))
            attributes["nook.agent.tokens." + kind] = .int(added)
            tokenSums.append(OTLPSum(name: "nook.agent.tokens", unit: "{token}", description: "Tokens agent turns used",
                                     attributes: ["nook.agent.provider": .string(run.provider.rawValue),
                                                  "nook.agent.token.type": .string(kind)], value: Double(added)))
        }
        let ok = run.status != .failed
        let span = OTLPSpan(traceID: OTLPPayload.randomID(bytes: 16), spanID: OTLPPayload.randomID(bytes: 8),
                            name: "nook.agent.turn", start: started, end: now, attributes: attributes,
                            ok: ok, statusMessage: ok ? nil : "failed")
        let byOutcome: [String: OTLPValue] = ["nook.agent.provider": .string(run.provider.rawValue),
                                              "nook.agent.outcome": .string(outcome)]
        let sums = [
            OTLPSum(name: "nook.agent.turns", unit: "{turn}", description: "Agent turns", attributes: byOutcome, value: 1),
            OTLPSum(name: "nook.agent.turn.duration", unit: "s", description: "Time agent turns took",
                    attributes: byOutcome, value: max(0, now.timeIntervalSince(started)), isInteger: false),
        ] + tokenSums
        let log = OTLPLogRecord(time: now, severity: run.status == .failed ? .error : (run.status == .stopped ? .warn : .info),
                                body: "agent turn " + outcome, attributes: byOutcome,
                                traceID: span.traceID, spanID: span.spanID)
        return (span, sums, log)
    }
}
