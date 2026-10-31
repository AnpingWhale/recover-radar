import Foundation
import RecoveryCore

public protocol COROSReadClient: Sendable {
    func discoverTools() async throws -> [MCPTool]
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult
}

extension COROSMCPClient: COROSReadClient {}

public struct MetricReadResult: Sendable {
    public let metric: RadarMetric
    public let range: DateInterval
    public let observations: [DailyObservation]
    public let confirmedDays: [Date]

    public init(metric: RadarMetric, range: DateInterval, observations: [DailyObservation], confirmedDays: [Date]) {
        self.metric = metric
        self.range = range
        self.observations = observations
        self.confirmedDays = confirmedDays
    }
}

public protocol DailyMetricSource: Sendable {
    func prepare() async throws
    func read(_ metric: RadarMetric, range: DateInterval, timeZone: TimeZone,
              fetchedAt: Date) async throws -> MetricReadResult
}

public struct COROSHealthDataSource: DailyMetricSource {
    private let client: any COROSReadClient
    public init(client: any COROSReadClient) { self.client = client }

    public func prepare() async throws { _ = try await client.discoverTools() }

    public func read(_ metric: RadarMetric, range: DateInterval, timeZone: TimeZone,
                     fetchedAt: Date) async throws -> MetricReadResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        var observations: [DailyObservation] = []
        var confirmedDays: [Date] = []
        let windows: [DateInterval]
        if metric == .hrv {
            // Keep the unused raw HRV series bounded; only official daily
            // assessment averages are parsed and retained.
            var cursor = range.start
            var chunks: [DateInterval] = []
            while cursor < range.end {
                let next = min(calendar.date(byAdding: .day, value: 7, to: cursor)!, range.end)
                chunks.append(DateInterval(start: cursor, end: next))
                cursor = next
            }
            windows = chunks
        } else { windows = [range] }

        for window in windows {
            try Task.checkCancellation()
            let arguments: [String: JSONValue]
            if metric == .sleepQuality || metric == .hrv {
                let lastDay = calendar.date(byAdding: .day, value: -1, to: window.end)!
                arguments = ["startDate": .string(formatter.string(from: window.start)),
                             "endDate": .string(formatter.string(from: lastDay))]
            } else {
                let days = calendar.dateComponents([.day], from: window.start, to: window.end).day!
                arguments = ["days": .number(Double(days))]
            }
            let result = try await client.callTool(name: metric.corosToolName, arguments: arguments)
            let decoded = try COROSHealthDecoder().decodeReport(result, metric: metric, range: window,
                                                               timeZone: timeZone, fetchedAt: fetchedAt)
            observations += decoded.observations
            confirmedDays += decoded.confirmedDays
        }
        return MetricReadResult(metric: metric, range: range, observations: observations, confirmedDays: confirmedDays)
    }
}

extension RadarMetric {
    public var corosToolName: String {
        switch self {
        case .sleepQuality: "querySleepOverview"
        case .hrv: "querySleepHrv"
        case .restingHeartRate: "queryRestingHeartRate"
        case .stressManagement: "queryStressLevel"
        case .trainingLoad: "queryTrainingLoadAssessment"
        }
    }
}
