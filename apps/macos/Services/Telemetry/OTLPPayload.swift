import Foundation

// The OTLP/HTTP JSON bodies Nook sends (`ExportTraceServiceRequest`, `ExportMetricsServiceRequest`,
// `ExportLogsServiceRequest`), written by hand instead of with the OpenTelemetry SDK: Nook sends a handful of spans,
// sums and log records, and the encoding is small. Per the OTLP JSON mapping, ids are lowercase hex, 64-bit integers
// (times in nanoseconds, integer values) are decimal strings, and enums are numbers. Foundation only, for the tests.

/// An attribute value.
enum OTLPValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    var json: [String: Any] {
        switch self {
        case .string(let value): return ["stringValue": value]
        case .int(let value): return ["intValue": String(value)]
        case .double(let value): return ["doubleValue": value]
        case .bool(let value): return ["boolValue": value]
        }
    }
}

struct OTLPSpan: Equatable, Sendable {
    var traceID: String
    var spanID: String
    var name: String
    var start: Date
    var end: Date
    var attributes: [String: OTLPValue] = [:]
    /// False marks the span as an error (`STATUS_CODE_ERROR`), with `statusMessage`.
    var ok = true
    var statusMessage: String? = nil
}

/// A monotonic sum over the export interval (delta temporality): a count of turns, tokens, seconds.
struct OTLPSum: Equatable, Sendable {
    var name: String
    var unit: String
    var description: String
    var attributes: [String: OTLPValue] = [:]
    var value: Double
    /// Sent as `asInt` (counts, tokens) instead of `asDouble` (seconds).
    var isInteger = true
}

struct OTLPLogRecord: Equatable, Sendable {
    enum Severity: Int, Sendable {
        // The OpenTelemetry severity numbers of the first level in each range.
        case info = 9, warn = 13, error = 17

        var text: String {
            switch self {
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    var time: Date
    var severity: Severity
    var body: String
    var attributes: [String: OTLPValue] = [:]
    var traceID: String? = nil
    var spanID: String? = nil
}

enum OTLPPayload {
    /// The instrumentation scope every record carries.
    static let scopeName = "nook"

    /// An export with nothing in it: what Test sends, which a receiver answers like any export.
    static func empty(_ signal: OTLPSignal) -> Data {
        encode([rootKey(signal): [Any]()])
    }

    static func traces(_ spans: [OTLPSpan], resource: [String: OTLPValue], version: String) -> Data {
        let items: [[String: Any]] = spans.map { span in
            var item: [String: Any] = [
                "traceId": span.traceID,
                "spanId": span.spanID,
                "name": span.name,
                // SPAN_KIND_INTERNAL
                "kind": 1,
                "startTimeUnixNano": nanos(span.start),
                "endTimeUnixNano": nanos(max(span.end, span.start)),
                "attributes": attributes(span.attributes),
            ]
            var status: [String: Any] = ["code": span.ok ? 1 : 2]
            if !span.ok, let message = span.statusMessage, !message.isEmpty { status["message"] = message }
            item["status"] = status
            return item
        }
        return wrap(.traces, resource: resource, version: version, recordsKey: "spans", records: items)
    }

    /// Sums of the same name become one metric with a data point per attribute set.
    static func metrics(_ sums: [OTLPSum], resource: [String: OTLPValue], version: String, start: Date, end: Date) -> Data {
        var order: [String] = []
        var grouped: [String: [OTLPSum]] = [:]
        for sum in sums {
            if grouped[sum.name] == nil { order.append(sum.name) }
            grouped[sum.name, default: []].append(sum)
        }
        let metrics: [[String: Any]] = order.map { name in
            let group = grouped[name] ?? []
            let points: [[String: Any]] = group.map { sum in
                var point: [String: Any] = [
                    "startTimeUnixNano": nanos(start),
                    "timeUnixNano": nanos(max(end, start)),
                    "attributes": attributes(sum.attributes),
                ]
                if sum.isInteger { point["asInt"] = String(Int(sum.value.rounded())) } else { point["asDouble"] = sum.value }
                return point
            }
            return [
                "name": name,
                "unit": group.first?.unit ?? "",
                "description": group.first?.description ?? "",
                // AGGREGATION_TEMPORALITY_DELTA: each export holds what happened since the last one.
                "sum": ["dataPoints": points, "aggregationTemporality": 1, "isMonotonic": true] as [String: Any],
            ]
        }
        return wrap(.metrics, resource: resource, version: version, recordsKey: "metrics", records: metrics)
    }

    static func logs(_ records: [OTLPLogRecord], resource: [String: OTLPValue], version: String) -> Data {
        let items: [[String: Any]] = records.map { record in
            var item: [String: Any] = [
                "timeUnixNano": nanos(record.time),
                "observedTimeUnixNano": nanos(record.time),
                "severityNumber": record.severity.rawValue,
                "severityText": record.severity.text,
                "body": ["stringValue": record.body],
                "attributes": attributes(record.attributes),
            ]
            if let trace = record.traceID { item["traceId"] = trace }
            if let span = record.spanID { item["spanId"] = span }
            return item
        }
        return wrap(.logs, resource: resource, version: version, recordsKey: "logRecords", records: items)
    }

    /// A random id of `bytes` bytes in lowercase hex: 16 for a trace, 8 for a span. Never all zeros (invalid in OTLP).
    static func randomID(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        while true {
            let values = (0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if values.contains(where: { $0 != 0 }) { return values.map { String(format: "%02x", $0) }.joined() }
        }
    }

    // MARK: Encoding

    static func rootKey(_ signal: OTLPSignal) -> String {
        switch signal {
        case .traces: return "resourceSpans"
        case .metrics: return "resourceMetrics"
        case .logs: return "resourceLogs"
        }
    }

    private static func scopeKey(_ signal: OTLPSignal) -> String {
        switch signal {
        case .traces: return "scopeSpans"
        case .metrics: return "scopeMetrics"
        case .logs: return "scopeLogs"
        }
    }

    private static func wrap(_ signal: OTLPSignal, resource: [String: OTLPValue], version: String, recordsKey: String,
                             records: [[String: Any]]) -> Data {
        let scope: [String: Any] = ["scope": ["name": scopeName, "version": version], recordsKey: records]
        let entry: [String: Any] = ["resource": ["attributes": attributes(resource)], scopeKey(signal): [scope]]
        return encode([rootKey(signal): [entry]])
    }

    static func attributes(_ values: [String: OTLPValue]) -> [[String: Any]] {
        values.keys.sorted().map { key in ["key": key, "value": values[key]!.json] }
    }

    static func nanos(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSince1970)
        return String(UInt64(seconds * 1_000_000) * 1_000)
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
