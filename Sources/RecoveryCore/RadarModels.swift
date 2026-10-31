import Foundation

/// The ordering is part of the widget snapshot contract.
public enum RadarMetric: String, Codable, CaseIterable, Sendable, Identifiable {
    case sleepQuality, hrv, restingHeartRate, stressManagement, trainingLoad

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sleepQuality: "睡眠质量"
        case .hrv: "HRV"
        case .restingHeartRate: "静息心率"
        case .stressManagement: "压力管理"
        case .trainingLoad: "运动负荷"
        }
    }

    public var unit: String {
        switch self {
        case .sleepQuality, .stressManagement: "分"
        case .hrv: "ms"
        case .restingHeartRate: "bpm"
        case .trainingLoad: "×"
        }
    }

    /// Display direction only; this is not a medical or training recommendation.
    public var outwardDirection: Double {
        switch self {
        case .restingHeartRate, .stressManagement: -1
        default: 1
        }
    }

    /// Fixed visual domains, not clinical reference ranges. Both series use
    /// the same transform, independent of the current history distribution.
    public var displayRange: ClosedRange<Double> {
        switch self {
        case .sleepQuality, .stressManagement: 0...100
        case .hrv: 0...150
        case .restingHeartRate: 40...100
        case .trainingLoad: 0...2
        }
    }

    public func displayIndex(for value: Double) -> Double? {
        guard accepts(value) else { return nil }
        let range = displayRange
        let bounded = min(range.upperBound, max(range.lowerBound, value))
        let fraction = (bounded - range.lowerBound) / (range.upperBound - range.lowerBound)
        return 100 * (outwardDirection > 0 ? fraction : 1 - fraction)
    }

    func accepts(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .sleepQuality, .stressManagement: return (0...100).contains(value)
        case .hrv, .restingHeartRate: return value > 0
        case .trainingLoad: return value >= 0
        }
    }
}

/// An adapter-normalized daily value. The COROS wire response is deliberately
/// not represented here; its schema must first be verified with the service.
public struct DailyObservation: Codable, Equatable, Sendable {
    public let metric: RadarMetric
    public let date: Date
    public let value: Double
    public let isComplete: Bool
    /// Explicit absence confirmed by a complete query, retained as a tombstone.
    public let isMissing: Bool
    /// The source revision time, or the last successful read when the source has
    /// no revision timestamp. It is not the physiological measurement time.
    public let updatedAt: Date

    public init(metric: RadarMetric, date: Date, value: Double,
                isComplete: Bool = true, updatedAt: Date, isMissing: Bool = false) {
        self.metric = metric
        self.date = date
        self.value = value
        self.isComplete = isComplete
        self.isMissing = isMissing
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case metric, date, value, isComplete, isMissing, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metric = try values.decode(RadarMetric.self, forKey: .metric)
        date = try values.decode(Date.self, forKey: .date)
        value = try values.decodeIfPresent(Double.self, forKey: .value) ?? .nan
        isComplete = try values.decode(Bool.self, forKey: .isComplete)
        isMissing = try values.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(metric, forKey: .metric)
        try values.encode(date, forKey: .date)
        // JSON null preserves an invalidation revision without persisting NaN or
        // infinity, and prevents an older valid value being resurrected later.
        if value.isFinite { try values.encode(value, forKey: .value) }
        else { try values.encodeNil(forKey: .value) }
        try values.encode(isComplete, forKey: .isComplete)
        try values.encode(isMissing, forKey: .isMissing)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metric == rhs.metric && lhs.date == rhs.date
            && (lhs.value == rhs.value || (!lhs.value.isFinite && !rhs.value.isFinite))
            && lhs.isComplete == rhs.isComplete && lhs.isMissing == rhs.isMissing
            && lhs.updatedAt == rhs.updatedAt
    }
}

public enum ConnectionState: String, Codable, Sendable {
    case disconnected, connected, reauthorizationRequired
}

public enum SyncState: String, Codable, Sendable {
    case idle, syncing, succeeded, partial, failed
}

/// Only local, fixed diagnostic categories are shared with the widget. Server
/// text, health payloads and authentication errors never become display strings.
public enum MetricAvailability: String, Codable, Sendable {
    case available, noData, unsupportedFormat, syncFailed, authenticationRequired
    case toolUnavailable, invalidData, notConnected

    public var title: String {
        switch self {
        case .available: "数据可用"
        case .noData: "暂无当日数据"
        case .unsupportedFormat: "暂不支持此数据格式"
        case .syncFailed: "同步失败，保留缓存"
        case .authenticationRequired: "需要重新连接"
        case .toolUnavailable: "服务暂未提供此指标"
        case .invalidData: "数据未通过校验"
        case .notConnected: "尚未连接"
        }
    }
}

/// The result of the most recent fetch for one metric, independent of cached
/// observations. A successful fetch does not prove that today's value exists.
public enum MetricFetchOutcome: Sendable, Equatable {
    case success, noData, unsupportedFormat, syncFailed, authenticationRequired
    case toolUnavailable, invalidData

    var availability: MetricAvailability? {
        switch self {
        case .success: nil
        case .noData: .noData
        case .unsupportedFormat: .unsupportedFormat
        case .syncFailed: .syncFailed
        case .authenticationRequired: .authenticationRequired
        case .toolUnavailable: .toolUnavailable
        case .invalidData: .invalidData
        }
    }
}

public struct RadarAxis: Codable, Equatable, Sendable, Identifiable {
    public let metric: RadarMetric
    public let currentValue: Double?
    public let baselineValue: Double?
    public let currentIndex: Double?
    public let baselineIndex: Double?
    public let sampleCount: Int
    public let isProvisional: Bool
    public let observedAt: Date?
    public let observedDay: Date?
    public let availability: MetricAvailability

    public var id: String { metric.id }

    public init(metric: RadarMetric, currentValue: Double?, baselineValue: Double?,
                currentIndex: Double?, baselineIndex: Double?, sampleCount: Int,
                isProvisional: Bool, observedAt: Date? = nil, observedDay: Date? = nil,
                availability: MetricAvailability? = nil) {
        self.metric = metric
        self.currentValue = currentValue
        self.baselineValue = baselineValue
        self.currentIndex = currentIndex
        self.baselineIndex = baselineIndex
        self.sampleCount = sampleCount
        self.isProvisional = isProvisional
        self.observedAt = observedAt
        self.observedDay = observedDay
        self.availability = availability ?? (currentValue == nil ? .noData : .available)
    }

    /// A failed fetch or another axis succeeding cannot make this value fresh.
    /// This is a display policy, not an assessment of physiological validity.
    public func isStale(at now: Date, timeZone: TimeZone) -> Bool {
        guard availability == .available, currentValue != nil,
              let observedAt, let observedDay else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return !calendar.isDate(observedDay, inSameDayAs: now)
            || now.timeIntervalSince(observedAt) >= RadarSnapshot.freshnessInterval
            || observedAt.timeIntervalSince(now) > 5 * 60
    }
}

/// The only health payload shared with the extension. It contains no tokens
/// and no full history. Change schemaVersion when this contract changes.
public struct RadarSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public static let freshnessInterval: TimeInterval = 6 * 60 * 60
    public let schemaVersion: Int
    /// When this file was composed, never a substitute for per-axis observedAt.
    public let generatedAt: Date
    public let day: Date
    public let timeZoneIdentifier: String
    public let axes: [RadarAxis]
    public let isDemo: Bool
    public let connectionState: ConnectionState
    public let syncState: SyncState
    public let lastAttemptAt: Date?

    public init(schemaVersion: Int = Self.currentSchemaVersion, generatedAt: Date,
                day: Date, timeZoneIdentifier: String, axes: [RadarAxis], isDemo: Bool,
                connectionState: ConnectionState = .connected,
                syncState: SyncState = .succeeded, lastAttemptAt: Date? = nil) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.axes = axes
        self.isDemo = isDemo
        self.connectionState = isDemo ? .disconnected : connectionState
        self.syncState = syncState
        self.lastAttemptAt = lastAttemptAt
    }

    /// Freshness belongs to each source observation. generatedAt is used only
    /// to age an empty snapshot; it never refreshes a retained health value.
    public func isStale(at now: Date) -> Bool {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard calendar.isDate(day, inSameDayAs: now),
              generatedAt.timeIntervalSince(now) <= 5 * 60 else { return true }
        let populated = axes.filter { $0.currentValue != nil }
        if populated.isEmpty {
            return now.timeIntervalSince(generatedAt) >= Self.freshnessInterval
        }
        return populated.contains { $0.isStale(at: now, timeZone: timeZone) }
    }
}

public enum WidgetConstants {
    public static let kind = "RecoverRadarWidget"
}
