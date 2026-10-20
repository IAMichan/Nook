import SwiftUI
import Charts

/// A chart in chat. A single series uses Nook's own color; multiple series use fixed colors in a set sequence
/// (a validated dark-background palette, easily distinguishable with color blindness).
struct ChatChartView: View {
    let chart: ChatChart

    static let palette: [Color] = [
        Color(hex: 0x3987E5), Color(hex: 0xD95926), Color(hex: 0x199E70), Color(hex: 0xC98500),
        Color(hex: 0xD55181), Color(hex: 0x008300), Color(hex: 0x9085E9), Color(hex: 0xE66767)
    ]

    private struct Row: Identifiable {
        let id: Int
        let series: String
        let label: String
        let value: Double
    }

    private var rows: [Row] {
        var result: [Row] = []
        for (s, series) in chart.series.enumerated() {
            let name = series.name.isEmpty ? "Reeks \(s + 1)" : series.name
            for point in series.points {
                result.append(Row(id: result.count, series: name, label: point.label, value: point.value))
            }
        }
        return result
    }

    private var multi: Bool { chart.series.count > 1 }
    private var labelBars: Bool { (chart.series.first?.points.count ?? 0) <= 12 }
    private var seriesNames: [String] {
        var seen = Set<String>()
        return rows.map(\.series).filter { seen.insert($0).inserted }
    }
    private var valueLabel: String { chart.unit.isEmpty ? "Waarde" : chart.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(chart.title.isEmpty ? "Grafiek" : chart.title)
                    .font(NookTheme.font(13.5, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Spacer()
                if !chart.unit.isEmpty {
                    Text(chart.unit)
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            if chart.kind == .pie {
                pie
            } else {
                xy.frame(height: 190)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.sheet).fill(NookTheme.field))
    }

    // MARK: Bar, line, area, points

    private var xy: some View {
        Chart(rows) { row in
            if chart.kind == .line {
                LineMark(x: .value("Label", row.label), y: .value(valueLabel, row.value))
                    .foregroundStyle(by: .value("Reeks", row.series))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Label", row.label), y: .value(valueLabel, row.value))
                    .foregroundStyle(by: .value("Reeks", row.series))
                    .symbolSize(30)
            } else if chart.kind == .area {
                AreaMark(x: .value("Label", row.label), y: .value(valueLabel, row.value))
                    .foregroundStyle(by: .value("Reeks", row.series))
                    .interpolationMethod(.monotone)
                    .opacity(multi ? 0.75 : 0.85)
            } else if chart.kind == .point {
                PointMark(x: .value("Label", row.label), y: .value(valueLabel, row.value))
                    .foregroundStyle(by: .value("Reeks", row.series))
                    .symbolSize(64)
            } else if multi {
                BarMark(x: .value("Label", row.label), y: .value(valueLabel, row.value), width: .ratio(0.8))
                    .foregroundStyle(by: .value("Reeks", row.series))
                    .position(by: .value("Reeks", row.series))
                    .cornerRadius(4)
            } else {
                BarMark(x: .value("Label", row.label), y: .value(valueLabel, row.value), width: .ratio(0.6))
                    .foregroundStyle(by: .value("Reeks", row.series))
                    .cornerRadius(4)
                    .annotation(position: .top, spacing: 3) {
                        // Show values above bars when few; omit when numerous to avoid clutter.
                        Text(Self.format(row.value))
                            .font(NookTheme.font(10, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                            .opacity(labelBars ? 1 : 0)
                    }
            }
        }
        .chartForegroundStyleScale(domain: seriesNames, range: multi ? Array(Self.palette.prefix(seriesNames.count)) : [NookTheme.iris])
        .chartLegend(multi ? .visible : .hidden)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(NookTheme.font(10.5))
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(NookTheme.line2)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Self.format(number))
                            .font(NookTheme.font(10.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: Pie

    private var slices: [Row] {
        let all = (chart.series.first?.points ?? []).enumerated().map { Row(id: $0.offset, series: $0.element.label, label: $0.element.label, value: max(0, $0.element.value)) }
        guard all.count > 7 else { return all }
        // More than seven slices: aggregate the smallest into "Other".
        let sorted = all.sorted { $0.value > $1.value }
        let rest = sorted.dropFirst(6).reduce(0) { $0 + $1.value }
        return Array(sorted.prefix(6)) + [Row(id: 999, series: "Overig", label: "Overig", value: rest)]
    }

    private var pie: some View {
        let parts = slices
        let total = max(parts.reduce(0) { $0 + $1.value }, .leastNonzeroMagnitude)
        return HStack(alignment: .center, spacing: 20) {
            Chart(parts) { part in
                SectorMark(angle: .value(valueLabel, part.value), innerRadius: .ratio(0.58), angularInset: 1.5)
                    .foregroundStyle(by: .value("Deel", part.label))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale(domain: parts.map(\.label), range: Array(Self.palette.prefix(parts.count)))
            .chartLegend(.hidden)
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.palette[index % Self.palette.count])
                            .frame(width: 10, height: 10)
                        Text(part.label)
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.format(part.value) + (chart.unit.isEmpty ? "" : " \(chart.unit)"))
                            .font(NookTheme.font(12, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                        Text("\(Int((part.value / total * 100).rounded()))%")
                            .font(NookTheme.font(11))
                            .foregroundStyle(NookTheme.textTertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    static func format(_ value: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.number
        if abs(value) >= 1_000_000 { return (value / 1_000_000).formatted(style.precision(.fractionLength(0...1))) + " mln" }
        if abs(value) >= 10_000 { return (value / 1_000).formatted(style.precision(.fractionLength(0...1))) + "k" }
        return value.formatted(style.precision(.fractionLength(0...2)))
    }
}
