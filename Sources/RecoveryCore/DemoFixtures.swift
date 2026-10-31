import Foundation

/// Entirely synthetic data. Never replace missing production data with these values.
public enum DemoFixtures {
    public static func snapshot(now: Date = .now) -> RadarSnapshot {
        let timeZone = TimeZone.current
        return BaselineEngine().snapshot(observations: observations(now: now, timeZone: timeZone),
                                         for: now, timeZone: timeZone, generatedAt: now, isDemo: true)
    }

    public static func observations(now: Date, timeZone: TimeZone) -> [DailyObservation] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        return (0...30).flatMap { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let wave = sin(Double(offset) * 0.7)
            let values: [Double] = offset == 0
                ? [86, 63, 51, 28, 1.15]
                : [80 + 7 * wave, 56 + 8 * wave, 54 + 3 * wave, 34 + 8 * wave, 1 + 0.16 * wave]
            return zip(RadarMetric.allCases, values).map { metric, value in
                DailyObservation(metric: metric, date: day, value: value,
                                 isComplete: offset > 0 || metric == .sleepQuality || metric == .hrv,
                                 updatedAt: offset == 0 ? now : day)
            }
        }
    }
}
