import SwiftUI
import RecoveryCore

/// A five-axis plot of relative indices. Missing values are gaps, never zeroes.
public struct RadarChartView: View {
    @Environment(\.colorSchemeContrast) private var contrast
    public let snapshot: RadarSnapshot
    public var showsLabels: Bool
    public var currentLabel: String
    public var monochrome: Bool
    public var compact: Bool
    public var showsValues: Bool
    public var stackedValues: Bool

    public init(snapshot: RadarSnapshot, showsLabels: Bool = true, currentLabel: String = "今日", monochrome: Bool = false, compact: Bool = false, showsValues: Bool = false, stackedValues: Bool = false) {
        self.snapshot = snapshot
        self.showsLabels = showsLabels
        self.currentLabel = currentLabel
        self.monochrome = monochrome
        self.compact = compact
        self.showsValues = showsValues
        self.stackedValues = stackedValues
    }

    private var currentColor: Color { monochrome ? .primary : .teal }
    private var gridOpacity: Double { contrast == .increased ? 0.5 : (monochrome ? 0.13 : 0.12) }

    private var axes: [RadarAxis?] {
        RadarMetric.allCases.map { metric in snapshot.axes.first { $0.metric == metric } }
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let radius = showsValues
                ? min(size.width * (stackedValues ? 0.36 : 0.32), size.height * 0.43)
                : min(size.width, size.height) * (compact ? 0.40 : (showsLabels ? 0.33 : 0.43))
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            ZStack {
                ForEach(1...3, id: \.self) { ring in
                    RadarPath(values: Array(repeating: Double(ring) * 100 / 3, count: 5), radius: radius)
                        .stroke(Color.primary.opacity(gridOpacity), lineWidth: 0.5)
                }
                Path { path in
                    for index in 0..<5 {
                        path.move(to: center)
                        path.addLine(to: point(index: index, value: 100, center: center, radius: radius))
                    }
                }
                .stroke(Color.primary.opacity(gridOpacity), lineWidth: 0.5)

                RadarPath(values: axes.map { $0?.baselineIndex }, radius: radius)
                    .stroke(Color.primary.opacity(contrast == .increased ? 0.9 : 0.50), style: StrokeStyle(lineWidth: contrast == .increased ? 1.5 : 0.85, dash: [2, 3]))

                if axes.allSatisfy({ $0?.currentIndex?.isFinite == true }) {
                    RadarPath(values: axes.map { $0?.currentIndex }, radius: radius)
                        .fill(currentColor.opacity(monochrome ? 0.045 : 0.10))
                }
                RadarPath(values: axes.map { $0?.currentIndex }, radius: radius)
                    .stroke(currentColor, style: StrokeStyle(lineWidth: contrast == .increased ? 2.5 : 1.4, lineCap: .round, lineJoin: .round))

                ForEach(Array(axes.enumerated()), id: \.offset) { index, axis in
                    if !compact, let value = axis?.baselineIndex, value.isFinite {
                        Circle()
                            .stroke(Color.primary.opacity(0.75), lineWidth: 1)
                            .frame(width: 4, height: 4)
                            .position(point(index: index, value: min(100, max(0, value)), center: center, radius: radius))
                    }
                    if !compact, let value = axis?.currentIndex, value.isFinite {
                        Circle()
                            .fill(currentColor)
                            .frame(width: compact ? 3 : 4, height: compact ? 3 : 4)
                            .position(point(index: index, value: min(100, max(0, value)), center: center, radius: radius))
                    }
                    if showsLabels {
                        if showsValues {
                            valueLabel(axis, metric: RadarMetric.allCases[index])
                                .position(labelPosition(index: index, center: center, radius: radius, size: size))
                        } else {
                            Text(compact ? shortTitle(RadarMetric.allCases[index]) : RadarMetric.allCases[index].title)
                                .font(.system(size: compact ? 8 : 10, weight: .regular))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .position(point(index: index, value: compact ? 115 : 130, center: center, radius: radius))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("睡眠与恢复雷达图")
        .accessibilityValue(axes.compactMap { axis in
            axis.map { "\($0.metric.title)，\(currentLabel)\(metricValue($0.currentValue, metric: $0.metric))，30天基线\(metricValue($0.baselineValue, metric: $0.metric))，基线样本\($0.sampleCount)天，\($0.availability.title)\($0.isProvisional ? "，日值更新中" : "")" }
        }.joined(separator: "；"))
    }
    private func valueLabel(_ axis: RadarAxis?, metric: RadarMetric) -> some View {
        Group {
            if stackedValues {
                VStack(spacing: 3) { valueLabelContent(axis, metric: metric) }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) { valueLabelContent(axis, metric: metric) }
            }
        }
        .fixedSize()
        .help("\(currentLabel)：\(metricValue(axis?.currentValue, metric: metric))；30天基线：\(metricValue(axis?.baselineValue, metric: metric))；\(axis?.sampleCount ?? 0)/30天")
    }

    @ViewBuilder private func valueLabelContent(_ axis: RadarAxis?, metric: RadarMetric) -> some View {
        Text(shortTitle(metric)).font(.system(size: 8)).foregroundStyle(.secondary)
        Text(axis?.currentValue.map { metricValue($0, metric: metric) } ?? "—")
            .font(.system(size: 9, weight: .regular, design: .rounded))
            .monospacedDigit()
    }

    private func shortTitle(_ metric: RadarMetric) -> String {
        switch metric {
        case .sleepQuality: "睡眠"
        case .hrv: "HRV"
        case .restingHeartRate: "静息"
        case .stressManagement: "压力"
        case .trainingLoad: "负荷"
        }
    }

    // Labels stay outside the outer grid, not on moving data points. This keeps
    // equal/overlapping series and clipped extremes readable without hiding data.
    private func labelPosition(index: Int, center: CGPoint, radius: Double, size: CGSize) -> CGPoint {
        let vertex = point(index: index, value: 100, center: center, radius: radius)
        let x: Double
        if index == 0 { x = center.x }
        else { x = vertex.x + (index <= 2 ? 1 : -1) * (stackedValues ? 24 : 36) }
        let y = index == 0 ? vertex.y - (stackedValues ? 20 : 10) : vertex.y
        let inset: Double = stackedValues ? 22 : 42
        return CGPoint(x: min(size.width - inset, max(inset, x)), y: min(size.height - 8, max(6, y)))
    }

}

private struct RadarPath: Shape {
    var values: [Double?]
    let radius: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let valid = values.map { value in value.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil } }
        return Path { path in
            if valid.allSatisfy({ $0 != nil }) {
                for (index, value) in valid.enumerated() {
                    guard let value else { continue }
                    let vertex = point(index: index, value: value, center: center, radius: radius)
                    if index == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
                }
                path.closeSubpath()
            } else {
                // Draw only adjacent available pairs, including the last/first pair.
                // The shape must not imply an observation on a missing axis.
                for index in valid.indices {
                    let next = (index + 1) % valid.count
                    guard let start = valid[index], let end = valid[next] else { continue }
                    path.move(to: point(index: index, value: start, center: center, radius: radius))
                    path.addLine(to: point(index: next, value: end, center: center, radius: radius))
                }
            }
        }
    }
}

private func point(index: Int, value: Double, center: CGPoint, radius: Double) -> CGPoint {
    let angle = Double(index) * 2 * .pi / 5 - .pi / 2
    // Labels intentionally use values above 100; observations are clamped by the path caller.
    let distance = radius * value / 100
    return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
}

public func metricValue(_ value: Double?, metric: RadarMetric) -> String {
    guard let value, value.isFinite else { return "暂无数据" }
    let digits = metric == .trainingLoad ? 2 : 0
    return value.formatted(.number.precision(.fractionLength(digits))) + " " + metric.unit
}
