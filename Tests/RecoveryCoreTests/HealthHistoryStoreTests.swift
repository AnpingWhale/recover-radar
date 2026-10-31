import Foundation
import Testing
@testable import RecoveryCore

struct HealthHistoryStoreTests {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let now = ISO8601DateFormatter().date(from: "2026-10-30T04:00:00Z")!

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func scope(connectionID: UUID = UUID(), region: String = "cn",
                       timeZone: String = "Asia/Shanghai") -> HistoryScope {
        HistoryScope(connectionID: connectionID, region: region, timeZoneIdentifier: timeZone)
    }

    private func day(_ offset: Int, at date: Date? = nil, timeZone: TimeZone? = nil) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? zone
        return calendar.date(byAdding: .day, value: offset,
                             to: calendar.startOfDay(for: date ?? now))!
    }

    private func observation(_ metric: RadarMetric = .hrv, offset: Int = 0,
                             value: Double = 60, revision: TimeInterval = 0) -> DailyObservation {
        DailyObservation(metric: metric, date: day(offset).addingTimeInterval(3600),
                         value: value, updatedAt: now.addingTimeInterval(revision))
    }

    @Test func normalizesDaysAndKeepsLatestRevisionAcrossReload() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = HealthHistoryStore(directory: path)
        let scope = scope()
        let initial = observation(value: 60, revision: -10)
        let corrected = observation(value: 70, revision: -5)
        let values = try await store.merge([initial, corrected], scope: scope, now: now)
        #expect(values.count == 1)
        #expect(values.first?.date == day(0))
        #expect(values.first?.value == 70)

        let reloaded = HealthHistoryStore(directory: path)
        let merged = try await reloaded.merge([initial], scope: scope, now: now)
        #expect(merged == values)
        // Equal revision timestamps keep the existing value deterministically.
        let tied = try await reloaded.merge([observation(value: 80, revision: -5)],
                                            scope: scope, now: now)
        #expect(tied.first?.value == 70)
    }

    @Test func invalidLatestRevisionIsPersistedAndNeverRevivesOldValue() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = HealthHistoryStore(directory: path)
        let scope = scope()
        let old = observation(value: 60, revision: -10)
        try await store.merge([old, observation(value: .infinity)], scope: scope, now: now)
        let restarted = HealthHistoryStore(directory: path)
        let values = try await restarted.merge([old], scope: scope, now: now)
        #expect(values.count == 1)
        #expect(values.first?.value.isNaN == true)
        let snapshot = BaselineEngine().snapshot(observations: values, for: now,
                                                 timeZone: zone, generatedAt: now)
        let axis = try #require(snapshot.axes.first { $0.metric == .hrv })
        #expect(axis.currentValue == nil)
        #expect(axis.availability == .invalidData)
    }

    @Test func sessionsRegionsAndTimeZonesAreIsolated() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = HealthHistoryStore(directory: path)
        let connection = UUID()
        let first = scope(connectionID: connection)
        let differentSession = scope()
        let differentRegion = scope(connectionID: connection, region: "eu")
        let differentZone = scope(connectionID: connection, timeZone: "Europe/Paris")
        try await store.merge([observation()], scope: first, now: now)
        for isolated in [differentSession, differentRegion, differentZone] {
            #expect(try await store.load(scope: isolated, now: now).isEmpty)
        }
        try await store.merge([observation(value: 90)], scope: differentRegion, now: now)
        #expect(try await store.load(scope: first, now: now).first?.value == 60)
        #expect(try await store.load(scope: differentRegion, now: now).first?.value == 90)
    }

    @Test func keepsNinetyCalendarDaysAcrossDSTAndPrunesWhenRead() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = HealthHistoryStore(directory: path)
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let target = ISO8601DateFormatter().date(from: "2026-03-10T19:00:00Z")!
        let scope = scope(timeZone: timeZone.identifier)
        let records = (-100...1).map { offset in
            DailyObservation(metric: .hrv, date: day(offset, at: target, timeZone: timeZone),
                             value: 60, updatedAt: target)
        }
        let retained = try await store.merge(records, scope: scope, now: target)
        #expect(retained.count == 90)
        #expect(retained.first?.date == day(-89, at: target, timeZone: timeZone))
        #expect(retained.last?.date == day(0, at: target, timeZone: timeZone))
        let followingDay = day(1, at: target, timeZone: timeZone)
        let pruned = try await store.load(scope: scope, now: followingDay)
        #expect(pruned.count == 89)
        #expect(pruned.first?.date == day(-88, at: target, timeZone: timeZone))
    }

    @Test func successfulCompleteReplacementWithdrawsMissingDaysOnlyInItsWindow() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = HealthHistoryStore(directory: path)
        let scope = scope()
        let oldToday = observation(value: 70, revision: -60)
        try await store.merge([oldToday, observation(offset: -1, revision: -60),
                               observation(.sleepQuality, value: 80, revision: -60)],
                              scope: scope, now: now)
        let replaced = try await store.replace(observations: [], metric: .hrv,
                                                in: DateInterval(start: day(0), end: day(1)),
                                                scope: scope, now: now)
        #expect(replaced.count == 3)
        #expect(replaced.first { $0.metric == .hrv && $0.date == day(0) }?.isMissing == true)
        #expect(replaced.first { $0.metric == .hrv && $0.date == day(-1) }?.value == 60)
        #expect(replaced.first { $0.metric == .sleepQuality }?.value == 80)
        let reloaded = HealthHistoryStore(directory: path)
        let afterDelayedReply = try await reloaded.merge([oldToday], scope: scope, now: now)
        #expect(afterDelayedReply.first { $0.metric == .hrv && $0.date == day(0) }?.isMissing == true)
        let snapshot = BaselineEngine().snapshot(observations: afterDelayedReply, for: now,
                                                 timeZone: zone, generatedAt: now)
        let hrv = try #require(snapshot.axes.first { $0.metric == .hrv })
        #expect(hrv.currentValue == nil)
        #expect(hrv.availability == .noData)
    }

    @Test func malformedReplacementDoesNotChangePersistedHistory() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = HealthHistoryStore(directory: path)
        let scope = scope()
        let before = try await store.merge([observation()], scope: scope, now: now)
        await #expect(throws: HealthHistoryStoreError.self) {
            try await store.replace(observations: [observation(.sleepQuality)], metric: .hrv,
                                    in: DateInterval(start: day(0), end: day(1)), scope: scope, now: now)
        }
        #expect(try await store.load(scope: scope, now: now) == before)
    }

    @Test func disconnectRemovalClearsOnlySelectedScopeAndRemoveAllIsIdempotent() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = HealthHistoryStore(directory: path)
        let first = scope()
        let second = scope()
        try await store.merge([observation()], scope: first, now: now)
        try await store.merge([observation()], scope: second, now: now)
        try await store.remove(scope: first)
        #expect(try await store.load(scope: first, now: now).isEmpty)
        #expect(try await store.load(scope: second, now: now).count == 1)
        try await store.removeAll()
        try await store.removeAll()
        #expect(try await store.load(scope: second, now: now).isEmpty)
    }
}
