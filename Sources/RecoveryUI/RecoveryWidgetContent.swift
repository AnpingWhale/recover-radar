import SwiftUI
import RecoveryCore

public enum RecoveryWidgetSize: String, CaseIterable, Sendable {
    case medium, large
    public var title: String { self == .medium ? "中号" : "大号" }
    public var previewWidth: CGFloat { 360 }
    public var previewHeight: CGFloat { self == .medium ? 170 : 382 }
}

/// The extension and the in-app gallery render this exact content.
/// WidgetKit owns its container/margins; the gallery supplies a reference-size shell.
public struct RecoveryWidgetContent: View {
    public let snapshot: RadarSnapshot
    public let size: RecoveryWidgetSize
    public let now: Date
    public let monochrome: Bool

    public init(snapshot: RadarSnapshot, size: RecoveryWidgetSize, now: Date = .now, monochrome: Bool = false) {
        self.snapshot = snapshot
        self.size = size
        self.now = now
        self.monochrome = monochrome
    }

    private var statusColor: Color { monochrome ? .primary : .orange }

    public var body: some View {
        Group {
            if size == .medium {
                RadarChartView(snapshot: snapshot, currentLabel: currentLabel(snapshot),
                               monochrome: monochrome, compact: true, showsValues: true)
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 10) {
                        RadarChartView(snapshot: snapshot, currentLabel: currentLabel(snapshot),
                                       monochrome: monochrome, compact: true, showsValues: true, stackedValues: true)
                            .frame(height: max(150, geometry.size.height - 116))
                        dataTable
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if snapshot.isDemo {
                Text("演示").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let status = statusMessage {
                Text(status).font(.system(size: 8)).foregroundStyle(statusColor)
            }
        }
    }

    private var dataTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                Text("数值").gridColumnAlignment(.trailing)
                Text("基线").gridColumnAlignment(.trailing)
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)

            Rectangle().fill(Color.primary.opacity(0.10))
                .frame(height: 0.5).gridCellColumns(3).gridCellUnsizedAxes(.horizontal)

            ForEach(snapshot.axes) { axis in
                GridRow {
                    Text(axis.metric.title)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(axis.currentValue.map { metricValue($0, metric: axis.metric) } ?? "—")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                    Text(axis.baselineValue.map { metricValue($0, metric: axis.metric) } ?? "—")
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .lineLimit(1)
                .help("30天基线：\(metricValue(axis.baselineValue, metric: axis.metric)) · \(axis.sampleCount)/30天")
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("指标明细")
        .accessibilityValue(snapshot.axes.map { axis in
            "\(axis.metric.title)，\(currentLabel(snapshot))\(metricValue(axis.currentValue, metric: axis.metric))，30天基线\(metricValue(axis.baselineValue, metric: axis.metric))，样本\(axis.sampleCount)天，\(axis.availability.title)\(axis.isProvisional ? "，暂定" : "")"
        }.joined(separator: "；"))
    }

    /// Keep exceptions visible even when the compact layout omits the data table.
    private var statusMessage: String? {
        if snapshot.connectionState == .reauthorizationRequired { return "需要重新连接" }
        if snapshot.syncState == .failed { return "同步失败 · 缓存" }
        if snapshot.syncState == .partial { return "部分待更新" }
        if snapshot.isStale(at: now) { return "缓存待更新" }
        if snapshot.axes.contains(where: { $0.baselineIndex == nil || $0.currentIndex == nil }) { return "部分数据不足" }
        return nil
    }

    private func currentLabel(_ snapshot: RadarSnapshot) -> String {
        snapshot.isStale(at: now) ? "缓存" : "今日"
    }

}
