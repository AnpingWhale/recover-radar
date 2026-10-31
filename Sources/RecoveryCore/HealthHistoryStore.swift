import Foundation

/// A random identifier for a connection, not an account ID. The application
/// creates a new connection ID after reconnecting and clears the old scope.
public struct HistoryScope: Codable, Hashable, Sendable {
    public let connectionID: UUID
    public let region: String
    public let timeZoneIdentifier: String

    public init(connectionID: UUID, region: String, timeZoneIdentifier: String) {
        self.connectionID = connectionID
        self.region = region
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public enum HealthHistoryStoreError: Error, LocalizedError {
    case invalidScope, invalidObservation, invalidRange, invalidHistory, unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidScope: "历史数据的连接或时区设置无效。"
        case .invalidObservation: "日值记录未通过校验。"
        case .invalidRange: "历史查询日期范围无效。"
        case .invalidHistory: "本地历史无法读取，请清除后重新同步。"
        case .unsupportedVersion: "本地历史版本不兼容，请清除后重新同步。"
        }
    }
}

/// The main application owns this store. It is deliberately independent of
/// App Groups, authentication and network contracts; the widget never uses it.
public actor HealthHistoryStore {
    public static let retentionDays = 90
    private static let schemaVersion = 1
    private let directory: URL

    private struct Document: Codable {
        let schemaVersion: Int
        let scope: HistoryScope
        let observations: [DailyObservation]
    }

    private struct Key: Hashable {
        let metric: RadarMetric
        let day: Date
    }

    public init(directory: URL) { self.directory = directory }

    /// Retains today and the previous 89 calendar days in this scope's time zone.
    public func load(scope: HistoryScope, now: Date = .now) throws -> [DailyObservation] {
        let calendar = try calendar(for: scope)
        let persisted = try read(scope: scope)
        let retained = try normalized(persisted, calendar: calendar, now: now)
        if retained != persisted { try write(retained, scope: scope) }
        return retained
    }

    /// The latest revision wins before value validation. Invalidations remain
    /// on disk as null values so a delayed older valid result cannot revive them.
    @discardableResult
    public func merge(_ observations: [DailyObservation], scope: HistoryScope,
                      now: Date = .now) throws -> [DailyObservation] {
        let calendar = try calendar(for: scope)
        let persisted = try read(scope: scope)
        let retained = try normalized(persisted + observations, calendar: calendar, now: now)
        try write(retained, scope: scope)
        return retained
    }

    /// Call only after successfully parsing a complete response for the whole
    /// half-open range. Failed or truncated requests must not call this method.
    /// Missing days become dated tombstones; older out-of-order replies cannot
    /// resurrect withdrawn values. The caller stamps each new observation with
    /// its source revision time or successful read time when none is available.
    @discardableResult
    public func replace(observations: [DailyObservation], metric: RadarMetric,
                        in range: DateInterval, scope: HistoryScope,
                        now: Date = .now) throws -> [DailyObservation] {
        let calendar = try calendar(for: scope)
        guard range.start.timeIntervalSinceReferenceDate.isFinite,
              range.end.timeIntervalSinceReferenceDate.isFinite,
              range.start < range.end,
              range.start == calendar.startOfDay(for: range.start),
              range.end == calendar.startOfDay(for: range.end),
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw HealthHistoryStoreError.invalidRange
        }
        guard observations.allSatisfy({ observation in
            observation.metric == metric && observation.date >= range.start
                && observation.date < range.end
        }) else { throw HealthHistoryStoreError.invalidObservation }

        let persisted = try read(scope: scope)
        let suppliedDays = Set(observations.map { calendar.startOfDay(for: $0.date) })
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var day = max(range.start, earliest)
        let end = min(range.end, tomorrow)
        var changes = observations
        while day < end {
            if !suppliedDays.contains(day) {
                changes.append(DailyObservation(metric: metric, date: day, value: .nan,
                                                isComplete: false, updatedAt: now, isMissing: true))
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let retained = try normalized(persisted + changes, calendar: calendar, now: now)
        try write(retained, scope: scope)
        return retained
    }

    public func remove(scope: HistoryScope) throws {
        let file = try fileURL(for: scope)
        do { try FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    /// Local removal never depends on successfully revoking a remote token.
    public func removeAll() throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    private func calendar(for scope: HistoryScope) throws -> Calendar {
        guard !scope.region.isEmpty, scope.region.utf8.count <= 64,
              let timeZone = TimeZone(identifier: scope.timeZoneIdentifier) else {
            throw HealthHistoryStoreError.invalidScope
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func fileURL(for scope: HistoryScope) throws -> URL {
        _ = try calendar(for: scope)
        // Components are encoded, never interpreted as a user-provided path.
        func component(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return directory.appendingPathComponent(scope.connectionID.uuidString, isDirectory: true)
            .appendingPathComponent(component(scope.region), isDirectory: true)
            .appendingPathComponent(component(scope.timeZoneIdentifier), isDirectory: true)
            .appendingPathComponent("daily-history.json")
    }

    private func read(scope: HistoryScope) throws -> [DailyObservation] {
        let data: Data
        do { data = try Data(contentsOf: fileURL(for: scope)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw HealthHistoryStoreError.invalidHistory }
        guard document.schemaVersion == Self.schemaVersion else {
            throw HealthHistoryStoreError.unsupportedVersion(document.schemaVersion)
        }
        guard document.scope == scope else { throw HealthHistoryStoreError.invalidHistory }
        return document.observations
    }

    private func write(_ observations: [DailyObservation], scope: HistoryScope) throws {
        let file = try fileURL(for: scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        // Foundation's numeric Date encoding preserves subsecond revisions.
        encoder.outputFormatting = [.sortedKeys]
        let document = Document(schemaVersion: Self.schemaVersion, scope: scope,
                                observations: observations)
        try encoder.encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func normalized(_ observations: [DailyObservation], calendar: Calendar,
                            now: Date) throws -> [DailyObservation] {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw HealthHistoryStoreError.invalidObservation
        }
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var latest: [Key: DailyObservation] = [:]
        for observation in observations {
            guard observation.date.timeIntervalSinceReferenceDate.isFinite,
                  observation.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw HealthHistoryStoreError.invalidObservation
            }
            let day = calendar.startOfDay(for: observation.date)
            guard day >= earliest, day < tomorrow else { continue }
            let key = Key(metric: observation.metric, day: day)
            if let old = latest[key], old.updatedAt >= observation.updatedAt { continue }
            latest[key] = DailyObservation(metric: observation.metric, date: day,
                                           value: observation.isMissing ? .nan : observation.value,
                                           isComplete: observation.isComplete,
                                           updatedAt: observation.updatedAt,
                                           isMissing: observation.isMissing)
        }
        return latest.values.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.metric.rawValue < $1.metric.rawValue
        }
    }
}
