import Foundation

/// The app owns synchronization. The widget never receives a data source.
/// Range is half-open, in the explicitly provided account time zone.
public protocol HealthDataSource: Sendable {
    func observations(in range: DateInterval, timeZone: TimeZone) async throws -> [DailyObservation]
}

public struct DemoHealthDataSource: HealthDataSource {
    public init() {}

    public func observations(in range: DateInterval, timeZone: TimeZone) async throws -> [DailyObservation] {
        DemoFixtures.observations(now: range.end.addingTimeInterval(-1), timeZone: timeZone)
            .filter { $0.date >= range.start && $0.date < range.end }
    }
}
