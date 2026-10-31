import Foundation

public enum SnapshotStoreError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalidSnapshot
    case unavailableAppGroup

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "缓存版本不兼容，请打开主应用更新数据。"
        case .invalidSnapshot: "缓存内容无效，请打开主应用重新同步。"
        case .unavailableAppGroup: "无法访问共享容器，请检查 App Group 与签名配置。"
        }
    }
}

public enum SharedContainer {
    public static func directory(appGroupIdentifier: String) throws -> URL {
        guard !appGroupIdentifier.isEmpty,
              let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
              ) else { throw SnapshotStoreError.unavailableAppGroup }
        return url.appendingPathComponent("RecoverRadar", isDirectory: true)
    }
}

/// App: single writer. Extension: read only. Atomic replacement keeps readers
/// from observing a partially written JSON document across the two processes.
public struct SnapshotStore: Sendable {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("radar-snapshot.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> RadarSnapshot? {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        // v1 lacks source times; v2 uses centered indices. Reject both rather
        // than presenting old plotting semantics as the current contract.
        struct VersionHeader: Decodable { let schemaVersion: Int }
        let version = try JSONDecoder().decode(VersionHeader.self, from: data).schemaVersion
        guard version == RadarSnapshot.currentSchemaVersion else {
            throw SnapshotStoreError.unsupportedVersion(version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RadarSnapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }

    public func save(_ snapshot: RadarSnapshot) throws {
        try validate(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func remove() throws {
        do { try FileManager.default.removeItem(at: fileURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    private func validate(_ snapshot: RadarSnapshot) throws {
        guard snapshot.schemaVersion == RadarSnapshot.currentSchemaVersion else {
            throw SnapshotStoreError.unsupportedVersion(snapshot.schemaVersion)
        }
        guard let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier),
              snapshot.generatedAt.timeIntervalSinceReferenceDate.isFinite,
              snapshot.day.timeIntervalSinceReferenceDate.isFinite,
              snapshot.lastAttemptAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              (!snapshot.isDemo || snapshot.connectionState == .disconnected),
              snapshot.axes.map(\.metric) == RadarMetric.allCases else {
            throw SnapshotStoreError.invalidSnapshot
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard snapshot.day == calendar.startOfDay(for: snapshot.day) else {
            throw SnapshotStoreError.invalidSnapshot
        }
        for axis in snapshot.axes {
            guard (0...30).contains(axis.sampleCount),
                  axis.observedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  axis.observedDay.map({ $0 == snapshot.day }) ?? true,
                  (axis.observedAt == nil) == (axis.observedDay == nil),
                  (axis.currentValue == nil || axis.observedAt != nil),
                  (axis.availability != .available || axis.currentValue != nil),
                  [axis.currentIndex, axis.baselineIndex].allSatisfy({
                      $0.map { $0.isFinite && (0...100).contains($0) } ?? true
                  }),
                  [axis.currentValue, axis.baselineValue].allSatisfy({
                      $0.map(axis.metric.accepts) ?? true
                  }),
                  (axis.currentIndex == nil || axis.currentValue != nil),
                  (axis.currentIndex == nil || axis.baselineIndex != nil),
                  (axis.baselineValue == nil) == (axis.baselineIndex == nil),
                  axis.baselineIndex == axis.baselineValue.flatMap { axis.metric.displayIndex(for: $0) },
                  axis.currentIndex == (axis.baselineValue == nil ? nil : axis.currentValue.flatMap { axis.metric.displayIndex(for: $0) }),
                  (axis.baselineIndex == nil || axis.sampleCount >= BaselineEngine.minimumSampleDays)
            else { throw SnapshotStoreError.invalidSnapshot }
        }
    }
}
