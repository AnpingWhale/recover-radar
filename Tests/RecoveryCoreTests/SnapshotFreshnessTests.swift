import Foundation
import Testing
@testable import RecoveryCore

struct SnapshotFreshnessTests {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let now = ISO8601DateFormatter().date(from: "2026-10-30T04:00:00Z")!

    private func observation(_ metric: RadarMetric, revision: TimeInterval = 0,
                             dayOffset: Int = 0) -> DailyObservation {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = calendar.date(byAdding: .day, value: dayOffset,
                                to: calendar.startOfDay(for: now))!
        return DailyObservation(metric: metric, date: day, value: 60,
                                updatedAt: now.addingTimeInterval(revision))
    }

    @Test func partialFailureRetainsSourceTimeAndCannotBecomeFreshThroughOtherAxis() throws {
        let old = observation(.hrv, revision: -7 * 60 * 60)
        let fresh = observation(.sleepQuality)
        let result = BaselineEngine().snapshot(observations: [old, fresh], for: now,
                                               timeZone: zone, generatedAt: now,
                                               outcomes: [.hrv: .syncFailed, .sleepQuality: .success],
                                               syncState: .partial, lastAttemptAt: now)
        let hrv = try #require(result.axes.first { $0.metric == .hrv })
        let sleep = try #require(result.axes.first { $0.metric == .sleepQuality })
        #expect(hrv.currentValue == 60)
        #expect(hrv.observedAt == old.updatedAt)
        #expect(hrv.availability == .syncFailed)
        #expect(hrv.isStale(at: now, timeZone: zone))
        #expect(!sleep.isStale(at: now, timeZone: zone))
        #expect(result.isStale(at: now))
        #expect(result.lastAttemptAt == now)
    }

    @Test func failedFetchMarksCachedValueEvenIfItsSourceTimeIsRecent() throws {
        let result = BaselineEngine().snapshot(observations: [observation(.hrv)], for: now,
                                               timeZone: zone, generatedAt: now,
                                               outcomes: [.hrv: .unsupportedFormat], syncState: .partial)
        let axis = try #require(result.axes.first { $0.metric == .hrv })
        #expect(axis.currentValue == 60)
        #expect(axis.availability == .unsupportedFormat)
        #expect(axis.isStale(at: now, timeZone: zone))
    }

    @Test func successfulFetchDoesNotOverrideOldSourceTimestamp() throws {
        let result = BaselineEngine().snapshot(observations: [observation(.hrv, revision: -7 * 60 * 60)],
                                               for: now, timeZone: zone, generatedAt: now,
                                               outcomes: [.hrv: .success])
        let axis = try #require(result.axes.first { $0.metric == .hrv })
        #expect(axis.availability == .available)
        #expect(axis.isStale(at: now, timeZone: zone))
        #expect(result.isStale(at: now))
    }

    @Test func previousDayIsNeverExposedAsTodayAndSuccessWithoutTodayRemainsNoData() throws {
        let result = BaselineEngine().snapshot(observations: [observation(.hrv, dayOffset: -1)],
                                               for: now, timeZone: zone, generatedAt: now,
                                               outcomes: [.hrv: .success])
        let axis = try #require(result.axes.first { $0.metric == .hrv })
        #expect(axis.currentValue == nil)
        #expect(axis.observedAt == nil)
        #expect(axis.observedDay == nil)
        #expect(axis.availability == .noData)
        #expect(axis.sampleCount == 1)
    }

    @Test func reauthorizationIsSharedAsSafeLocalStateAndDemoNeverClaimsConnection() {
        let result = BaselineEngine().snapshot(observations: [observation(.hrv)], for: now,
                                               timeZone: zone, generatedAt: now,
                                               connectionState: .reauthorizationRequired,
                                               syncState: .failed, lastAttemptAt: now)
        #expect(result.connectionState == .reauthorizationRequired)
        #expect(result.axes.allSatisfy { $0.availability == .authenticationRequired })
        #expect(DemoFixtures.snapshot(now: now).connectionState == .disconnected)
    }
}
