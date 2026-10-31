import Foundation
import Testing
@testable import RecoveryCore

struct BaselineEngineTests {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private var now: Date { date("2026-10-30T04:00:00Z") }

    private func observation(_ metric: RadarMetric = .hrv, offset: Int, value: Double,
                             complete: Bool = true, revision: TimeInterval = 0) -> DailyObservation {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        return DailyObservation(metric: metric, date: day, value: value,
                                isComplete: complete, updatedAt: day.addingTimeInterval(revision))
    }

    private func snapshot(_ observations: [DailyObservation]) -> RadarSnapshot {
        BaselineEngine().snapshot(observations: observations, for: now,
                                  timeZone: timeZone, generatedAt: now)
    }

    private func axis(_ snapshot: RadarSnapshot, _ metric: RadarMetric = .hrv) -> RadarAxis {
        snapshot.axes.first { $0.metric == metric }!
    }

    @Test func testWindowExcludesTodayFutureAndThirtyFirstDay() {
        let history = (-30 ... -1).map { observation(offset: $0, value: 60) }
        let result = axis(snapshot(history + [
            observation(offset: -31, value: 600), observation(offset: 0, value: 90),
            observation(offset: 1, value: 700)
        ]))
        #expect(result.sampleCount == 30)
        #expect(result.baselineValue == 60)
        #expect(result.currentValue == 90)
        #expect(result.baselineIndex == 40)
        #expect(result.currentIndex == 60)
    }

    @Test func testEachAxisHasIndependentSevenDayMinimum() {
        let hrv = (-6 ... -1).map { observation(offset: $0, value: 60) }
        let sleep = (-7 ... -1).map { observation(.sleepQuality, offset: $0, value: 80) }
        let result = snapshot(hrv + sleep + [observation(offset: 0, value: 70)])
        #expect(axis(result).baselineIndex == nil)
        #expect(axis(result).currentIndex == nil)
        #expect(axis(result).currentValue == 70)
        #expect(axis(result, .sleepQuality).baselineValue == 80)
        #expect(axis(result, .sleepQuality).currentValue == nil)
    }

    @Test func testMedianResistsOneExtremeHistoricalValue() {
        let history = (-8 ... -1).map { observation(offset: $0, value: $0 == -1 ? 500 : 60) }
        #expect(axis(snapshot(history)).baselineValue == 60)
    }

    @Test func testLatestCorrectionWinsAndDaysAreNotDoubleCounted() {
        let history = (-7 ... -1).map { observation(offset: $0, value: 60) }
        let correction = observation(offset: -1, value: 100, revision: 1)
        let invalidation = observation(offset: -2, value: .nan, revision: 1)
        let result = axis(snapshot(history + [correction, invalidation]))
        #expect(result.sampleCount == 6)
        #expect(result.baselineValue == nil)
    }

    @Test func testIncompleteHistoryExcludedAndCurrentMarkedProvisional() {
        let history = (-8 ... -1).map { observation(offset: $0, value: 60, complete: $0 != -1) }
        let result = axis(snapshot(history + [observation(offset: 0, value: 65, complete: false)]))
        #expect(result.sampleCount == 7)
        #expect(result.isProvisional)
        #expect(result.currentIndex != nil)
    }

    @Test func testDirectionAndScaleAreMetricSpecific() throws {
        let data = RadarMetric.allCases.flatMap { metric in
            let baseline: Double = metric == .trainingLoad ? 1 : 60
            let current: Double = metric == .trainingLoad ? 1.05 : 63
            return (-7 ... -1).map { observation(metric, offset: $0, value: baseline) }
                + [observation(metric, offset: 0, value: current)]
        }
        let result = snapshot(data)
        let hrv = try #require(axis(result).currentIndex)
        let restingHeartRate = try #require(axis(result, .restingHeartRate).currentIndex)
        let stressManagement = try #require(axis(result, .stressManagement).currentIndex)
        let trainingLoad = try #require(axis(result, .trainingLoad).currentIndex)
        #expect(abs(hrv - 42) <= 0.0001)
        #expect(abs(restingHeartRate - (100 * 37.0 / 60)) <= 0.0001)
        #expect(abs(stressManagement - 37) <= 0.0001)
        #expect(abs(trainingLoad - 52.5) <= 0.0001)
    }

    @Test func testZeroLoadIsValidButZeroHRVIsMissing() {
        let data = (-7...0).flatMap { day in [
            observation(.trainingLoad, offset: day, value: 0),
            observation(.hrv, offset: day, value: 0)
        ] }
        let result = snapshot(data)
        #expect(axis(result, .trainingLoad).currentIndex == 0)
        #expect(axis(result, .trainingLoad).sampleCount == 7)
        #expect(axis(result).currentValue == nil)
        #expect(axis(result).sampleCount == 0)
    }

    @Test func baselineMovesWhileSameValueKeepsSamePosition() {
        let low = (-30 ... -1).map { observation(offset: $0, value: 45) }
        let high = (-30 ... -1).map { observation(offset: $0, value: 90) }
        let today = observation(offset: 0, value: 75)
        let a = axis(snapshot(low + [today]))
        let b = axis(snapshot(high + [today]))
        #expect(a.baselineIndex == 30)
        #expect(b.baselineIndex == 60)
        #expect(a.currentIndex == b.currentIndex)
        #expect(a.currentIndex == 50)
        let equal = axis(snapshot(high + [observation(offset: 0, value: 90)]))
        #expect(equal.currentIndex == equal.baselineIndex)
    }

    @Test func fixedDomainsClampWithoutLosingRawValues() {
        for metric in RadarMetric.allCases {
            #expect(metric.displayIndex(for: .nan) == nil)
            #expect(metric.displayIndex(for: .infinity) == nil)
        }
        #expect(RadarMetric.hrv.displayIndex(for: 300) == 100)
        #expect(RadarMetric.restingHeartRate.displayIndex(for: 30) == 100)
        #expect(RadarMetric.restingHeartRate.displayIndex(for: 120) == 0)
        let data = (-7 ... -1).map { observation(offset: $0, value: 60) }
        let result = axis(snapshot(data + [observation(offset: 0, value: 300)]))
        #expect(result.currentIndex == 100)
        #expect(result.currentValue == 300)
        #expect(Set(DemoFixtures.snapshot(now: now).axes.compactMap(\.baselineIndex)).count > 1)
    }

    @Test func testCalendarWindowAcrossDSTAndYearBoundary() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        for target in [date("2026-03-10T19:00:00Z"), date("2027-01-05T20:00:00Z")] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let today = calendar.startOfDay(for: target)
            let history = (-31 ... -1).map { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: today)!
                return DailyObservation(metric: .hrv, date: day, value: 60, updatedAt: day)
            }
            let result = BaselineEngine().snapshot(observations: history, for: target,
                                                  timeZone: zone, generatedAt: target)
            #expect(axis(result).sampleCount == 30)
            #expect(result.day == today)
        }
    }

    @Test func testNonFiniteAndOutOfDomainValuesAreMissing() {
        let result = snapshot([
            observation(.sleepQuality, offset: 0, value: 101),
            observation(.hrv, offset: 0, value: .infinity),
            observation(.restingHeartRate, offset: 0, value: -5),
            observation(.stressManagement, offset: 0, value: .nan),
            observation(.trainingLoad, offset: 0, value: -1)
        ])
        #expect(result.axes.allSatisfy { $0.currentValue == nil && $0.currentIndex == nil })
        #expect(!result.isDemo)
    }

    @Test func testStaleAtAccountMidnightEvenBeforeSixHourTTL() {
        let generated = date("2026-10-30T15:59:00Z")
        let result = BaselineEngine().snapshot(observations: [], for: generated,
                                              timeZone: timeZone, generatedAt: generated)
        #expect(!result.isStale(at: generated))
        #expect(result.isStale(at: date("2026-10-30T16:01:00Z")))
    }

    @Test func testSyntheticSnapshotAlwaysLabelledDemo() {
        let result = DemoFixtures.snapshot(now: now)
        #expect(result.isDemo)
        #expect(result.axes.count == 5)
        #expect(result.axes.allSatisfy { $0.sampleCount == 30 })
    }
}
