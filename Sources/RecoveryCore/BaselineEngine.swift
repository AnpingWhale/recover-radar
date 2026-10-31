import Foundation

/// A deterministic, local display transform. The resulting index must never
/// be presented as a COROS recovery score or used for training advice.
public struct BaselineEngine: Sendable {
    public static let windowDays = 30
    public static let minimumSampleDays = 7

    public init() {}

    public func snapshot(observations: [DailyObservation], for date: Date,
                         timeZone: TimeZone, generatedAt: Date,
                         isDemo: Bool = false,
                         outcomes: [RadarMetric: MetricFetchOutcome] = [:],
                         connectionState: ConnectionState = .connected,
                         syncState: SyncState = .succeeded,
                         lastAttemptAt: Date? = nil) -> RadarSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: date)
        // Calendar arithmetic preserves calendar-day boundaries across DST.
        let start = calendar.date(byAdding: .day, value: -Self.windowDays, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let axes = RadarMetric.allCases.map { metric in
            var latestByDay: [Date: DailyObservation] = [:]
            for observation in observations where observation.metric == metric {
                guard observation.date.timeIntervalSinceReferenceDate.isFinite,
                      observation.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                      observation.date >= start, observation.date < tomorrow else { continue }
                let day = calendar.startOfDay(for: observation.date)
                if let previous = latestByDay[day], previous.updatedAt >= observation.updatedAt {
                    continue
                }
                latestByDay[day] = observation
            }

            // Select the latest revision before validation: an invalid/incomplete
            // correction must not silently resurrect an older value for that day.
            let history = latestByDay.compactMap { day, observation -> Double? in
                guard day < today, observation.isComplete, !observation.isMissing,
                      metric.accepts(observation.value) else { return nil }
                return observation.value
            }
            let latestCurrent = latestByDay[today]
            let current = latestCurrent.flatMap {
                !$0.isMissing && metric.accepts($0.value) ? $0 : nil
            }
            let availability: MetricAvailability
            if !isDemo && connectionState == .disconnected {
                availability = .notConnected
            } else if !isDemo && connectionState == .reauthorizationRequired {
                availability = .authenticationRequired
            } else if let status = outcomes[metric]?.availability {
                availability = status
            } else if current != nil {
                availability = .available
            } else {
                availability = latestCurrent != nil && latestCurrent?.isMissing == false
                    ? .invalidData : .noData
            }
            let baseline = history.count >= Self.minimumSampleDays ? Self.median(history) : nil
            let currentIndex = baseline == nil ? nil : current.flatMap { metric.displayIndex(for: $0.value) }
            return RadarAxis(metric: metric, currentValue: current?.value,
                             baselineValue: baseline, currentIndex: currentIndex,
                             baselineIndex: baseline.flatMap { metric.displayIndex(for: $0) }, sampleCount: history.count,
                             isProvisional: current.map { !$0.isComplete } ?? false,
                             observedAt: latestCurrent?.updatedAt,
                             observedDay: latestCurrent.map { _ in today },
                             availability: availability)
        }
        return RadarSnapshot(generatedAt: generatedAt, day: today,
                             timeZoneIdentifier: timeZone.identifier, axes: axes, isDemo: isDemo,
                             connectionState: connectionState, syncState: syncState,
                             lastAttemptAt: lastAttemptAt)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] / 2 + sorted[middle] / 2
        }
        return sorted[middle]
    }
}
