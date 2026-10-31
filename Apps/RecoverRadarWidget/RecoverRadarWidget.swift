import SwiftUI
import WidgetKit
import RecoveryCore
import RecoveryUI

private enum CacheState: Sendable {
    case snapshot(RadarSnapshot)
    case empty
    case failed
}

private struct RadarEntry: TimelineEntry {
    let date: Date
    let state: CacheState
}

/// WidgetKit reads a local, atomic snapshot only. Authentication and sync belong to the app.
private struct RadarProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadarEntry {
        RadarEntry(date: .now, state: .snapshot(DemoFixtures.snapshot()))
    }

    func getSnapshot(in context: Context, completion: @escaping (RadarEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(readCache())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadarEntry>) -> Void) {
        let entry = readCache()
        var entries = [entry]
        if case .snapshot(let snapshot) = entry.state {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
            let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: entry.date))
            let expirations = snapshot.axes.compactMap(\.observedAt).map { $0.addingTimeInterval(RadarSnapshot.freshnessInterval) }
                + [snapshot.generatedAt.addingTimeInterval(RadarSnapshot.freshnessInterval)]
            // Pre-schedule freshness transitions even if WidgetKit delays its next reload.
            let transitions = Set([nextMidnight].compactMap { $0 } + expirations)
                .filter { $0 > entry.date }
                .sorted()
            entries += transitions.map { RadarEntry(date: $0, state: entry.state) }
        }
        // A refresh is a request, never a scheduling guarantee. No network work runs here.
        completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(60 * 60))))
    }

    private func readCache() -> RadarEntry {
        do {
            guard let identifier = Bundle.main.object(forInfoDictionaryKey: "RecoverRadarAppGroupIdentifier") as? String,
                  !identifier.isEmpty, !identifier.contains("$(") else {
                return RadarEntry(date: .now, state: .failed)
            }
            let directory = try SharedContainer.directory(appGroupIdentifier: identifier)
            let snapshot = try SnapshotStore(directory: directory).load()
            return RadarEntry(date: .now, state: snapshot.map(CacheState.snapshot) ?? .empty)
        } catch {
            return RadarEntry(date: .now, state: .failed)
        }
    }
}

private struct RadarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: RadarEntry

    var body: some View {
        Group {
            switch entry.state {
            case .snapshot(let snapshot):
                RecoveryWidgetContent(snapshot: snapshot, size: family == .systemLarge ? .large : .medium,
                                      now: entry.date, monochrome: renderingMode != .fullColor)
            case .empty:
                unavailable(title: "还没有恢复数据", description: "请打开 Recovery Radar\n连接 COROS 或预览演示。", icon: "waveform.path.ecg")
            case .failed:
                unavailable(title: "无法读取共享缓存", description: "请打开 Recovery Radar\n检查数据与 App Group 配置。", icon: "exclamationmark.triangle")
            }
        }
        // WidgetKit replaces this removable background with system Liquid Glass in
        // Clear/Tinted appearance. Never layer an app glassEffect over that surface.
        .containerBackground(for: .widget) { Color(.windowBackgroundColor) }
        .widgetURL(URL(string: "recoverradar://dashboard"))
    }

    private func unavailable(title: String, description: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2)
                .foregroundStyle(renderingMode == .fullColor ? Color.teal : Color.primary)
                .widgetAccentable()
            Text(title).font(.headline)
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

@main
struct RecoverRadarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetConstants.kind, provider: RadarProvider()) { entry in
            RadarWidgetView(entry: entry)
        }
        .configurationDisplayName("Recovery Radar")
        .description("今日睡眠与恢复指标，以及过去30天的个人基线。")
        .supportedFamilies([.systemMedium, .systemLarge])
        .containerBackgroundRemovable(true)
    }
}
