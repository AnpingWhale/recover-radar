import Foundation
import RecoveryCore

public enum HealthDecodingError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat
    case invalidRecord
    case unexpectedDate

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "COROS 返回格式暂不支持，未更新此指标。"
        case .invalidRecord: "COROS 返回了无法验证的指标记录，已保留旧数据。"
        case .unexpectedDate: "返回日期与所选时区不一致，请检查 COROS 账号时区。"
        }
    }
}

public struct DecodedHealthReport: Sendable {
    public let observations: [DailyObservation]
    /// Only dates explicitly present in the report are authoritative, including
    /// rows saying No data. A shorter result must never erase unreturned history.
    public let confirmedDays: [Date]
}

/// Strict parser for the English daily report format observed on 2026-10-30.
/// It deliberately does not guess JSON fields or derive HRV from raw samples.
public struct COROSHealthDecoder: Sendable {
    public static let contractVersion = "coros-daily-text-2026-10-30"
    public init() {}

    public func decode(_ result: MCPToolResult, metric: RadarMetric, range: DateInterval,
                       timeZone: TimeZone, fetchedAt: Date) throws -> [DailyObservation] {
        try decodeReport(result, metric: metric, range: range, timeZone: timeZone,
                         fetchedAt: fetchedAt).observations
    }

    public func decodeReport(_ result: MCPToolResult, metric: RadarMetric, range: DateInterval,
                             timeZone: TimeZone, fetchedAt: Date) throws -> DecodedHealthReport {
        guard !result.isError else { throw HealthDecodingError.unsupportedFormat }
        let blocks = result.textContent.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard blocks.count == 1 else { throw HealthDecodingError.unsupportedFormat }
        var report = blocks[0].trimmingCharacters(in: .whitespacesAndNewlines)
        // Some MCP hosts encode a returned String as JSON inside a text block.
        if report.hasPrefix("\"") {
            guard let data = report.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                throw HealthDecodingError.unsupportedFormat
            }
            report = decoded
        }
        var lines = report.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first = lines.first, matchesHeader(first, metric: metric) else {
            throw HealthDecodingError.unsupportedFormat
        }
        if metric == .hrv {
            guard let assessment = lines.firstIndex(where: { $0.hasPrefix("HRV Assessment — ") }),
                  let timeSeries = lines.firstIndex(where: { $0.hasPrefix("Sleep HRV Time Series — ") }),
                  assessment < timeSeries else { throw HealthDecodingError.unsupportedFormat }
            lines = Array(lines[(assessment + 1)..<timeSeries])
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: fetchedAt)
        var records: [DailyObservation] = []
        var seenDates = Set<Date>()
        var currentDate: Date?
        var valueSeen = false

        func finishRecord() throws {
            if currentDate != nil && !valueSeen { throw HealthDecodingError.invalidRecord }
        }

        for line in lines {
            let datePattern = metric == .restingHeartRate
                ? #"^(\d{4}-\d{2}-\d{2}):\s*(.+)$"#
                : #"^(\d{4}-\d{2}-\d{2}):?$"#
            if let fields = captures(datePattern, in: line) {
                try finishRecord()
                guard let day = parseDate(fields[0], timeZone: timeZone) else {
                    throw HealthDecodingError.invalidRecord
                }
                guard day >= range.start, day < range.end else { throw HealthDecodingError.unexpectedDate }
                guard seenDates.insert(day).inserted else { throw HealthDecodingError.invalidRecord }
                currentDate = day
                valueSeen = false
                if metric == .restingHeartRate {
                    valueSeen = true
                    if let value = try numericValue(fields[1], metric: metric) {
                        records.append(observation(metric, day: day, value: value, today: today, fetchedAt: fetchedAt))
                    }
                }
                continue
            }
            guard let currentDate else { continue }
            guard let rawValue = fieldValue(line, metric: metric) else { continue }
            guard !valueSeen else { throw HealthDecodingError.invalidRecord }
            valueSeen = true
            if let value = try numericValue(rawValue, metric: metric) {
                records.append(observation(metric, day: currentDate, value: value, today: today, fetchedAt: fetchedAt))
            }
        }
        try finishRecord()
        // Only documented/observed record shapes are accepted. Unknown empty
        // prose must not erase a previously good history window.
        guard !seenDates.isEmpty else { throw HealthDecodingError.unsupportedFormat }
        return DecodedHealthReport(observations: records, confirmedDays: seenDates.sorted())
    }

    private func matchesHeader(_ line: String, metric: RadarMetric) -> Bool {
        switch metric {
        case .sleepQuality: line == "Sleep Overview"
        case .hrv: line.hasPrefix("Sleep HRV — ")
        case .restingHeartRate: line.hasPrefix("Resting Heart Rate — Last ")
        case .stressManagement: line.hasPrefix("Stress Level — Last ")
        case .trainingLoad: line == "Training Load Assessment"
        }
    }

    private func fieldValue(_ line: String, metric: RadarMetric) -> String? {
        let prefix: String
        switch metric {
        case .sleepQuality: prefix = "Sleep Score: "
        case .hrv: prefix = "HRV Avg: "
        case .restingHeartRate: return nil
        case .stressManagement: prefix = "Average Stress: "
        case .trainingLoad: prefix = "Load Ratio: "
        }
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    private func numericValue(_ text: String, metric: RadarMetric) throws -> Double? {
        if text == "No data" { return nil }
        let pattern: String
        switch metric {
        case .hrv: pattern = #"^([0-9]+(?:\.[0-9]+)?) ms(?: — [^\r\n]+)?$"#
        case .restingHeartRate: pattern = #"^([0-9]+(?:\.[0-9]+)?) bpm$"#
        default: pattern = #"^([0-9]+(?:\.[0-9]+)?)$"#
        }
        guard let fields = captures(pattern, in: text), let value = Double(fields[0]), value.isFinite else {
            throw HealthDecodingError.invalidRecord
        }
        switch metric {
        case .sleepQuality, .stressManagement:
            guard (0...100).contains(value) else { throw HealthDecodingError.invalidRecord }
        case .hrv, .restingHeartRate:
            guard value > 0 else { throw HealthDecodingError.invalidRecord }
        case .trainingLoad: break
        }
        return value
    }

    private func observation(_ metric: RadarMetric, day: Date, value: Double,
                             today: Date, fetchedAt: Date) -> DailyObservation {
        DailyObservation(metric: metric, date: day, value: value,
                         isComplete: day < today || metric == .sleepQuality || metric == .hrv,
                         updatedAt: fetchedAt)
    }

    private func parseDate(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    private func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
