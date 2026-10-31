import SwiftUI
import RecoveryCore

public struct RadarLegendView: View {
    public let currentLabel: String
    public let monochrome: Bool

    public init(currentLabel: String = "今日", monochrome: Bool = false) {
        self.currentLabel = currentLabel
        self.monochrome = monochrome
    }

    public var body: some View {
        HStack(spacing: 16) {
            Label {
                Text(currentLabel).foregroundStyle(.secondary)
            } icon: {
                Path { path in path.move(to: CGPoint(x: 0, y: 1)); path.addLine(to: CGPoint(x: 18, y: 1)) }
                    .stroke(monochrome ? Color.primary : Color.teal, lineWidth: 2).frame(width: 18, height: 2)
            }
            Label {
                Text("30天基线").foregroundStyle(.secondary)
            } icon: {
                Rectangle()
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 18, height: 1)
            }
        }
        .font(.caption)
    }
}

/// Shared, accessible presentation for the app and the larger widget.
public struct RecoveryDashboardView: View {
    public let snapshot: RadarSnapshot
    public let now: Date

    public init(snapshot: RadarSnapshot, now: Date = .now) {
        self.snapshot = snapshot
        self.now = now
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("睡眠与恢复").font(.headline)
                Spacer()
                if snapshot.isDemo {
                    Text("演示数据")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            RadarChartView(snapshot: snapshot, currentLabel: snapshot.isStale(at: now) ? "缓存" : "今日")
                .frame(minHeight: 180, idealHeight: 260, maxHeight: 300)
            RadarLegendView(currentLabel: snapshot.isStale(at: now) ? "缓存" : "今日")
            ForEach(snapshot.axes) { axis in
                let zone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
                let stale = axis.isStale(at: now, timeZone: zone)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(axis.metric.title)
                            if axis.metric == .stressManagement {
                                Text("原值：平均压力")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if axis.isProvisional {
                            Text("未完整日").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(metricValue(axis.currentValue, metric: axis.metric))
                            .monospacedDigit()
                        Text("基线 " + metricValue(axis.baselineValue, metric: axis.metric))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 115, alignment: .trailing)
                        Text("\(axis.sampleCount)/30天")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .font(.callout)
                    .help("过去30个完整日中有 \(axis.sampleCount) 天可用；至少7天才能绘制该轴。")
                    HStack(spacing: 8) {
                        if axis.availability != .available {
                            Text(axis.availability.title).foregroundStyle(.orange)
                        } else if stale {
                            Text("缓存待更新").foregroundStyle(.orange)
                        }
                        if let observedAt = axis.observedAt {
                            Text("读取于 \(observedAt.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                }
            }
        }
    }
}
