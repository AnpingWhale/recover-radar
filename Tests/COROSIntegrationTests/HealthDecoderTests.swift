import Foundation
import Testing
import RecoveryCore
@testable import COROSIntegration

struct HealthDecoderTests {
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    let now = ISO8601DateFormatter().date(from: "2026-10-30T08:00:00Z")!

    var window: DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        return DateInterval(start: calendar.date(byAdding: .day, value: -30, to: today)!,
                            end: calendar.date(byAdding: .day, value: 1, to: today)!)
    }

    func decode(_ text: String, metric: RadarMetric) throws -> [DailyObservation] {
        try COROSHealthDecoder().decode(MCPToolResult(content: [.init(type: "text", text: text)]),
                                         metric: metric, range: window, timeZone: zone, fetchedAt: now)
    }

    @Test func fiveObservedReportShapesWithSyntheticValues() throws {
        let reports: [(RadarMetric, String, Double)] = [
            (.sleepQuality, "Sleep Overview\n2026-10-30\nSleep Score: 84\nDaily Sleep: 8h 2min", 84),
            (.hrv, "Sleep HRV — 2026-10-30\nHRV Assessment — Last 1 days\n2026-10-30:\nHRV Avg: 62 ms — Normal\nBaseline: 55 ms\nSleep HRV Time Series — Last 1 days\n2026-10-30:\ntimestamp=123, hrv=900 ms", 62),
            (.restingHeartRate, "Resting Heart Rate — Last 1 days\n2026-10-30: 52 bpm", 52),
            (.stressManagement, "Stress Level — Last 1 days\n2026-10-30:\nAverage Stress: 29\nRelaxed: No data", 29),
            (.trainingLoad, "Training Load Assessment\n2026-10-30\nShort-Term Load: 46\nLong-Term Load: 40\nLoad Ratio: 1.15", 1.15)
        ]
        for (metric, report, value) in reports {
            let records = try decode(report, metric: metric)
            #expect(records.count == 1)
            #expect(records.first?.value == value)
            #expect(records.first?.isComplete == (metric == .sleepQuality || metric == .hrv))
        }
    }

    @Test func JSONEncodedStringIsUnwrapped() throws {
        let report = "Sleep Overview\n2026-10-30\nSleep Score: 84"
        let encoded = String(data: try JSONEncoder().encode(report), encoding: .utf8)!
        #expect(try decode(encoded, metric: .sleepQuality).first?.value == 84)
    }

    @Test func missingAndZeroAreDifferent() throws {
        let records = try decode("Training Load Assessment\n2026-10-29\nLoad Ratio: No data\n2026-10-30\nLoad Ratio: 0", metric: .trainingLoad)
        #expect(records.count == 1)
        #expect(records.first?.value == 0)
    }

    @Test func malformedOrRenamedFieldCannotEraseHistory() {
        #expect(throws: HealthDecodingError.invalidRecord) {
            try decode("Sleep Overview\n2026-10-30\nNew Score: 84", metric: .sleepQuality)
        }
        #expect(throws: HealthDecodingError.invalidRecord) {
            try decode("Sleep Overview\n2026-10-30\nSleep Score: NaN", metric: .sleepQuality)
        }
        #expect(throws: HealthDecodingError.invalidRecord) {
            try decode("Sleep Overview\n2026-10-30\nSleep Score: 101", metric: .sleepQuality)
        }
    }

    @Test func duplicateDateAndWrongUnitRejected() {
        #expect(throws: HealthDecodingError.invalidRecord) {
            try decode("Resting Heart Rate — Last 2 days\n2026-10-30: 50 bpm\n2026-10-30: 51 bpm", metric: .restingHeartRate)
        }
        #expect(throws: HealthDecodingError.invalidRecord) {
            try decode("Resting Heart Rate — Last 1 days\n2026-10-30: 50 ms", metric: .restingHeartRate)
        }
    }

    @Test func wrongWindowAndInvalidDateRejected() {
        #expect(throws: HealthDecodingError.unexpectedDate) {
            try decode("Sleep Overview\n2026-10-31\nSleep Score: 84", metric: .sleepQuality)
        }
        #expect(throws: HealthDecodingError.invalidRecord) {
            try decode("Sleep Overview\n2026-02-30\nSleep Score: 84", metric: .sleepQuality)
        }
    }

    @Test func unknownStructuredSchemaIsNotGuessed() {
        let result = MCPToolResult(content: [], structuredContent: .object(["score": .number(84)]))
        #expect(throws: HealthDecodingError.unsupportedFormat) {
            try COROSHealthDecoder().decode(result, metric: .sleepQuality, range: window,
                                            timeZone: zone, fetchedAt: now)
        }
    }

    @Test func HRVNeverUsesRawSamplesWithoutOfficialAssessment() {
        #expect(throws: HealthDecodingError.unsupportedFormat) {
            try decode("Sleep HRV — 2026-10-30\nSleep HRV Time Series — Last 1 days\n2026-10-30:\nhrv=999 ms", metric: .hrv)
        }
    }

    @Test func olderDaysAreCompleteButNotShiftedToSleepStartDate() throws {
        let records = try decode("Sleep Overview\n2026-10-29\nSleep Score: 84\nMain Sleep Window: 2026-10-28 23:00 - 2026-10-29 07:00", metric: .sleepQuality)
        #expect(records.first?.isComplete == true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        #expect(calendar.component(.day, from: try #require(records.first?.date)) == 29)
    }
}
