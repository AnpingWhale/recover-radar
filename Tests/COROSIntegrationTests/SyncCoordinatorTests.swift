import Foundation
import Testing
import RecoveryCore
@testable import COROSIntegration

private struct SyncFixture: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = ISO8601DateFormatter().date(from: "2026-10-30T08:00:00Z")!
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    let scope = HistoryScope(connectionID: UUID(), region: "cn", timeZoneIdentifier: "Asia/Shanghai")
    var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = zone
        return result
    }
    var history: HealthHistoryStore { HealthHistoryStore(directory: directory.appendingPathComponent("private")) }
    var snapshots: SnapshotStore { SnapshotStore(directory: directory.appendingPathComponent("shared")) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }
    func value(_ metric: RadarMetric) -> Double {
        switch metric {
        case .sleepQuality: 84
        case .hrv: 62
        case .restingHeartRate: 52
        case .stressManagement: 29
        case .trainingLoad: 1.1
        }
    }
    func observation(_ metric: RadarMetric, offset: Int = 0, value: Double? = nil, updatedAt: Date? = nil) -> DailyObservation {
        DailyObservation(metric: metric, date: day(offset), value: value ?? self.value(metric),
                         isComplete: offset < 0 || metric == .sleepQuality || metric == .hrv,
                         updatedAt: updatedAt ?? now)
    }
    func today(_ metric: RadarMetric, range: DateInterval) -> MetricReadResult {
        MetricReadResult(metric: metric, range: range, observations: [observation(metric)], confirmedDays: [day(0)])
    }
    func coordinator(source: any DailyMetricSource) -> SyncCoordinator {
        SyncCoordinator(source: source, history: history, snapshots: snapshots, scope: scope)
    }
}

private actor SyncReadGate {
    private var entered = false
    private var cancelled = false
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var enterObserver: CheckedContinuation<Void, Never>?
    private var cancelObserver: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        enterObserver?.resume()
        enterObserver = nil
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterObserver = $0 }
    }
    func recordCancellation() {
        cancelled = true
        cancelObserver?.resume()
        cancelObserver = nil
    }
    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancelObserver = $0 }
    }
    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}

private actor SyntheticMetricSource: DailyMetricSource {
    private var prepares = 0
    private var reads: [RadarMetric] = []
    private let gate: SyncReadGate?
    private let delay: Duration?
    private let handler: @Sendable (RadarMetric, DateInterval) throws -> MetricReadResult

    init(gate: SyncReadGate? = nil, delay: Duration? = nil,
         handler: @escaping @Sendable (RadarMetric, DateInterval) throws -> MetricReadResult) {
        self.gate = gate
        self.delay = delay
        self.handler = handler
    }
    func prepare() async throws { prepares += 1 }
    func read(_ metric: RadarMetric, range: DateInterval, timeZone: TimeZone, fetchedAt: Date) async throws -> MetricReadResult {
        reads.append(metric)
        if reads.count == 1 {
            if let gate {
                // Deliberately simulate a transport that delivers a late value after cancellation.
                await withTaskCancellationHandler { await gate.wait() } onCancel: {
                    Task { await gate.recordCancellation() }
                }
            }
            if let delay { try await Task.sleep(for: delay) }
        }
        return try handler(metric, range)
    }
    func counts() -> (prepares: Int, reads: [RadarMetric]) { (prepares, reads) }
}

struct SyncCoordinatorTests {
    @Test func successfulSyncPersistsThirtyDayBaselinesAndCurrentSnapshot() async throws {
        let fixture = SyncFixture()
        defer { fixture.cleanup() }
        let source = SyntheticMetricSource { metric, range in
            MetricReadResult(metric: metric, range: range,
                             observations: (-30...0).map { fixture.observation(metric, offset: $0) },
                             confirmedDays: (-30...0).map(fixture.day))
        }
        let result = try await fixture.coordinator(source: source).synchronize(now: fixture.now)
        #expect(result.syncState == .succeeded)
        #expect(result.connectionState == .connected)
        #expect(!result.isDemo)
        #expect(result.axes.allSatisfy { $0.sampleCount == 30 && $0.availability == .available && $0.observedAt == fixture.now })
        #expect(try fixture.snapshots.load() == result)
        #expect(try await fixture.history.load(scope: fixture.scope, now: fixture.now).count == 155)
    }

    @Test func partialFailurePreservesEachRetainedValuesOwnTimestamp() async throws {
        let fixture = SyncFixture()
        defer { fixture.cleanup() }
        let oldTime = fixture.now.addingTimeInterval(-3_600)
        try await fixture.history.merge([fixture.observation(.hrv, value: 57, updatedAt: oldTime)], scope: fixture.scope, now: fixture.now)
        let source = SyntheticMetricSource { metric, range in
            if metric == .hrv { throw MCPClientError.httpStatus(503) }
            return fixture.today(metric, range: range)
        }
        let result = try await fixture.coordinator(source: source).synchronize(now: fixture.now)
        let hrv = try #require(result.axes.first { $0.metric == .hrv })
        #expect(result.syncState == .partial)
        #expect(hrv.currentValue == 57)
        #expect(hrv.observedAt == oldTime)
        #expect(hrv.availability == .syncFailed)
        #expect(result.axes.filter { $0.metric != .hrv }.allSatisfy { $0.observedAt == fixture.now && $0.availability == .available })
    }

    @Test func explicitNoDataWithdrawsOldValueWithoutInventingZero() async throws {
        let fixture = SyncFixture()
        defer { fixture.cleanup() }
        let old = fixture.observation(.hrv, value: 57, updatedAt: fixture.now.addingTimeInterval(-3_600))
        try await fixture.history.merge([old], scope: fixture.scope, now: fixture.now)
        let source = SyntheticMetricSource { metric, range in
            if metric == .hrv {
                return MetricReadResult(metric: metric, range: range, observations: [], confirmedDays: [fixture.day(0)])
            }
            return fixture.today(metric, range: range)
        }
        let result = try await fixture.coordinator(source: source).synchronize(now: fixture.now)
        let hrv = try #require(result.axes.first { $0.metric == .hrv })
        #expect(hrv.currentValue == nil)
        #expect(hrv.availability == .noData)
        let persisted = try await fixture.history.load(scope: fixture.scope, now: fixture.now)
        #expect(persisted.first { $0.metric == .hrv }?.isMissing == true)
        // A delayed older reply must not revive the withdrawn record.
        let delayed = try await fixture.history.merge([old], scope: fixture.scope, now: fixture.now)
        #expect(delayed.first { $0.metric == .hrv }?.isMissing == true)
    }

    @Test func unreturnedTodayIsAFailedRefreshRatherThanConfirmedAbsence() async throws {
        let fixture = SyncFixture()
        defer { fixture.cleanup() }
        let oldTime = fixture.now.addingTimeInterval(-3_600)
        try await fixture.history.merge([fixture.observation(.hrv, value: 57, updatedAt: oldTime)], scope: fixture.scope, now: fixture.now)
        let source = SyntheticMetricSource { metric, range in
            if metric == .hrv {
                return MetricReadResult(metric: metric, range: range,
                                        observations: [fixture.observation(metric, offset: -1)], confirmedDays: [fixture.day(-1)])
            }
            return fixture.today(metric, range: range)
        }
        let result = try await fixture.coordinator(source: source).synchronize(now: fixture.now)
        let hrv = try #require(result.axes.first { $0.metric == .hrv })
        #expect(hrv.currentValue == 57)
        #expect(hrv.observedAt == oldTime)
        #expect(hrv.availability == .syncFailed)
        #expect(result.syncState == .partial)
    }

    @Test func nonconsecutiveConfirmedDaysCannotDeleteUnreportedHistoryGaps() async throws {
        let fixture = SyncFixture()
        defer { fixture.cleanup() }
        let oldTime = fixture.now.addingTimeInterval(-3_600)
        let originals = (-3...0).map { fixture.observation(.hrv, offset: $0, value: 57, updatedAt: oldTime) }
        try await fixture.history.merge(originals, scope: fixture.scope, now: fixture.now)
        let source = SyntheticMetricSource { metric, range in
            if metric == .hrv {
                return MetricReadResult(metric: metric, range: range,
                                        observations: [fixture.observation(metric, value: 65)],
                                        confirmedDays: [fixture.day(-2), fixture.day(0)])
            }
            return fixture.today(metric, range: range)
        }
        _ = try await fixture.coordinator(source: source).synchronize(now: fixture.now)
        let persisted = try await fixture.history.load(scope: fixture.scope, now: fixture.now).filter { $0.metric == .hrv }
        #expect(persisted.first { $0.date == fixture.day(-3) }?.value == 57)
        #expect(persisted.first { $0.date == fixture.day(-2) }?.isMissing == true)
        #expect(persisted.first { $0.date == fixture.day(-1) }?.value == 57)
        #expect(persisted.first { $0.date == fixture.day(-1) }?.updatedAt == oldTime)
        #expect(persisted.first { $0.date == fixture.day(0) }?.value == 65)
    }

    @Test func cancellationDrainsLateResponseBeforeDisconnectCanClearFiles() async throws {
        let fixture = SyncFixture()
        defer { fixture.cleanup() }
        let old = fixture.observation(.hrv, value: 57, updatedAt: fixture.now.addingTimeInterval(-3_600))
        try await fixture.history.merge([old], scope: fixture.scope, now: fixture.now)
        let oldSnapshot = BaselineEngine().snapshot(observations: [old], for: fixture.now, timeZone: fixture.zone,
                                                    generatedAt: old.updatedAt)
        try fixture.snapshots.save(oldSnapshot)
        let gate = SyncReadGate()
        let source = SyntheticMetricSource(gate: gate) { metric, range in fixture.today(metric, range: range) }
        let coordinator = fixture.coordinator(source: source)
        let syncing = Task { try await coordinator.synchronize(now: fixture.now) }
        await gate.waitUntilEntered()
        let cancelling = Task { await coordinator.cancelAndWait() }
        await gate.waitUntilCancelled()
        await gate.release()
        await cancelling.value
        await #expect(throws: CancellationError.self) { try await syncing.value }
        #expect(try fixture.snapshots.load() == oldSnapshot)
        #expect(try await fixture.history.load(scope: fixture.scope, now: fixture.now) == [old])
        try await fixture.history.removeAll()
        try fixture.snapshots.remove()
        #expect(try fixture.snapshots.load() == nil)
        #expect(try await fixture.history.load(scope: fixture.scope, now: fixture.now).isEmpty)
    }

    @Test func overlappingSyncRequestsShareOneFetchAndOneResult() async throws {
        let fixture = SyncFixture()
        defer { fixture.cleanup() }
        let source = SyntheticMetricSource(delay: .milliseconds(30)) { metric, range in fixture.today(metric, range: range) }
        let coordinator = fixture.coordinator(source: source)
        let results = try await withThrowingTaskGroup(of: RadarSnapshot.self) { group in
            for _ in 0..<8 { group.addTask { try await coordinator.synchronize(now: fixture.now) } }
            var values = [RadarSnapshot]()
            for try await value in group { values.append(value) }
            return values
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == results.first })
        let counts = await source.counts()
        #expect(counts.prepares == 1)
        #expect(counts.reads == RadarMetric.allCases)
    }
}
