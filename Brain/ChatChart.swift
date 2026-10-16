import Foundation

/// A chart rendered by Nook in chat.
struct ChatChart: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case bar, line, area, pie, point }

    struct Point: Equatable {
        var label: String
        var value: Double
    }

    struct Series: Equatable {
        var name: String
        var points: [Point]
    }

    let id = UUID()
    var title: String
    var kind: Kind
    var unit: String
    var series: [Series]

    /// Parses a chart from model tool input. Accepts series with points (or data), or a flat data array.
    static func parse(_ input: [String: Any]) -> ChatChart? {
        let title = (input["title"] as? String) ?? ""
        let kind = Kind(rawValue: ((input["type"] as? String) ?? "bar").lowercased()) ?? .bar
        let unit = (input["unit"] as? String) ?? ""

        func points(_ raw: Any?) -> [Point] {
            ((raw as? [Any]) ?? []).compactMap { item in
                guard let object = item as? [String: Any] else { return nil }
                let label = (object["label"] as? String) ?? (object["x"].map { "\($0)" }) ?? ""
                guard let value = number(object["value"] ?? object["y"]) else { return nil }
                return Point(label: label, value: value)
            }
        }

        var series: [Series] = ((input["series"] as? [Any]) ?? []).compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            let list = points(object["points"] ?? object["data"])
            return list.isEmpty ? nil : Series(name: (object["name"] as? String) ?? "", points: list)
        }
        if series.isEmpty {
            let list = points(input["data"] ?? input["points"])
            if !list.isEmpty { series = [Series(name: title, points: list)] }
        }
        guard !series.isEmpty else { return nil }
        return ChatChart(title: title, kind: kind, unit: unit, series: Array(series.prefix(8)))
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String:
            let cleaned = value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
            return Double(cleaned)
        default: return nil
        }
    }
}
