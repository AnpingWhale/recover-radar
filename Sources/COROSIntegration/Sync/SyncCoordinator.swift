import Foundation
import RecoveryCore

/// One coordinator per connection and time zone. Cancellation is drained before
/// disconnect clears files, so a late response cannot restore a previous account.
public actor SyncCoordinator {
    private let source: any DailyMetricSource
    private let history: HealthHistoryStore
    private let snapshots: SnapshotStore
    private let scope: HistoryScope
    private var operation: (id: UUID, task: Task<RadarSnapshot, any Error>)?

    public init(source: any DailyMetricSource, history: HealthHistoryStore,
                snapshots: SnapshotStore, scope: HistoryScope) {
        self.source = source
        self.history = history
        self.snapshots = snapshots
        self.scope = scope
    }

    public func synchronize(now: Date = .now) async throws -> RadarSnapshot {
        if let operation { return try await operation.task.value }
        let id = UUID()
        let task = Task { try await self.performSync(now: now) }
        operation = (id, task)
        defer { if operation?.id == id { operation = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func cancelAndWait() async {
        guard let current = operation else { return }
        current.task.cancel()
        _ = await current.task.result
        if operation?.id == current.id { operation = nil }
    }

    private func performSync(now: Date) async throws -> RadarSnapshot {
        guard let timeZone = TimeZone(identifier: scope.timeZoneIdentifier) else {
            throw HealthHistoryStoreError.invalidScope
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let window = DateInterval(start: calendar.date(byAdding: .day, value: -30, to: today)!,
                                  end: calendar.date(byAdding: .day, value: 1, to: today)!)
        var observations = try await history.load(scope: scope, now: now)
        var outcomes: [RadarMetric: MetricFetchOutcome] = [:]
        do {
            try await source.prepare()
        } catch {
            try Task.checkCancellation()
            let outcome = Self.classify(error)
            outcomes = Dictionary(uniqueKeysWithValues: RadarMetric.allCases.map { ($0, outcome) })
        }

        if outcomes.isEmpty {
            for metric in RadarMetric.allCases {
                try Task.checkCancellation()
                do {
                    let result = try await source.read(metric, range: window, timeZone: timeZone, fetchedAt: now)
                    try Task.checkCancellation()
                    let days = Set(result.confirmedDays)
                    guard result.metric == metric, result.range == window, !days.isEmpty,
                          days.allSatisfy({ $0 >= window.start && $0 < window.end && $0 == calendar.startOfDay(for: $0) }),
                          result.observations.allSatisfy({ $0.metric == metric && days.contains($0.date) }) else {
                        throw HealthDecodingError.invalidRecord
                    }
                    // A service may return fewer days than requested. Replace
                    // only explicitly confirmed consecutive date runs.
                    for confirmedRange in Self.ranges(for: days.sorted(), calendar: calendar) {
                        try Task.checkCancellation()
                        let values = result.observations.filter { $0.date >= confirmedRange.start && $0.date < confirmedRange.end }
                        observations = try await history.replace(observations: values, metric: metric,
                                                                  in: confirmedRange, scope: scope, now: now)
                    }
                    outcomes[metric] = !days.contains(today) ? .syncFailed
                        : (result.observations.contains { calendar.isDate($0.date, inSameDayAs: today) && !$0.isMissing }
                           ? .success : .noData)
                } catch {
                    try Task.checkCancellation()
                    // A storage failure is not a remote partial failure. Surface it
                    // instead of silently claiming the new values were persisted.
                    if error is HealthHistoryStoreError || error is CocoaError { throw error }
                    outcomes[metric] = Self.classify(error)
                    if outcomes[metric] == .authenticationRequired {
                        for remaining in RadarMetric.allCases where outcomes[remaining] == nil {
                            outcomes[remaining] = .authenticationRequired
                        }
                        break
                    }
                }
            }
        }
        try Task.checkCancellation()
        let successful = outcomes.values.filter { $0 == .success || $0 == .noData }.count
        let state: SyncState = outcomes.values.allSatisfy { $0 == .success } ? .succeeded
            : (successful == 0 ? .failed : .partial)
        let connection: ConnectionState = outcomes.values.contains(.authenticationRequired)
            ? .reauthorizationRequired : .connected
        let snapshot = BaselineEngine().snapshot(observations: observations, for: now,
                                                 timeZone: timeZone, generatedAt: now,
                                                 outcomes: outcomes, connectionState: connection,
                                                 syncState: state, lastAttemptAt: now)
        try Task.checkCancellation()
        try snapshots.save(snapshot)
        return snapshot
    }

    private static func ranges(for days: [Date], calendar: Calendar) -> [DateInterval] {
        var ranges: [DateInterval] = []
        for day in days {
            let end = calendar.date(byAdding: .day, value: 1, to: day)!
            if let previous = ranges.last, previous.end == day {
                ranges[ranges.count - 1] = DateInterval(start: previous.start, end: end)
            } else {
                ranges.append(DateInterval(start: day, end: end))
            }
        }
        return ranges
    }

    private static func classify(_ error: any Error) -> MetricFetchOutcome {
        switch error {
        case OAuthError.notConnected, OAuthError.requiresAuthorization,
             OAuthError.invalidStoredCredentials, MCPClientError.invalidAccessToken,
             MCPClientError.httpStatus(401), MCPClientError.httpStatus(403):
            return .authenticationRequired
        case MCPClientError.toolUnavailable, MCPClientError.toolsNotSupported:
            return .toolUnavailable
        case HealthDecodingError.unsupportedFormat, MCPClientError.unsupportedInputSchema,
             MCPClientError.unsupportedContentType, MCPClientError.unsupportedProtocolVersion:
            return .unsupportedFormat
        case HealthDecodingError.invalidRecord, HealthDecodingError.unexpectedDate,
             MCPClientError.malformedResponse:
            return .invalidData
        default: return .syncFailed
        }
    }
}
