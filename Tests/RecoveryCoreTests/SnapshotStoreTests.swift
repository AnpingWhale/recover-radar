import Foundation
import Testing
@testable import RecoveryCore

struct SnapshotStoreTests {
    private func withStore(_ body: (SnapshotStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SnapshotStore(directory: directory), directory)
    }

    @Test func testMissingRoundTripAndDeletion() throws {
        try withStore { store, _ in
            #expect(try store.load() == nil)
            let snapshot = DemoFixtures.snapshot()
            try store.save(snapshot)
            let loaded = try #require(try store.load())
            #expect(loaded.isDemo)
            #expect(loaded.axes.map(\.currentValue) == snapshot.axes.map(\.currentValue))
            #expect(loaded.timeZoneIdentifier == snapshot.timeZoneIdentifier)
            try store.remove()
            #expect(try store.load() == nil)
            try store.remove()
        }
    }

    @Test func testCorruptFileThrowsInsteadOfReturningDemo() throws {
        try withStore { store, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not JSON".utf8).write(to: directory.appendingPathComponent("radar-snapshot.json"))
            #expect(throws: (any Error).self) { try store.load() }
        }
    }

    @Test func testInvalidSnapshotDoesNotReplaceGoodCache() throws {
        try withStore { store, _ in
            let valid = DemoFixtures.snapshot()
            try store.save(valid)
            let invalid = RadarSnapshot(schemaVersion: 999, generatedAt: valid.generatedAt,
                                        day: valid.day, timeZoneIdentifier: valid.timeZoneIdentifier,
                                        axes: valid.axes, isDemo: false)
            #expect(throws: (any Error).self) { try store.save(invalid) }
            let loaded = try #require(try store.load())
            #expect(loaded.isDemo)
        }
    }

    @Test func testUnsupportedVersionOnDiskIsRejected() throws {
        try withStore { store, directory in
            try store.save(DemoFixtures.snapshot())
            let file = directory.appendingPathComponent("radar-snapshot.json")
            let decodedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            var json = try #require(decodedJSON as? [String: Any])
            json["schemaVersion"] = 999
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            #expect { try store.load() } throws: { error in
                guard case SnapshotStoreError.unsupportedVersion(999) = error else {
                    return false
                }
                return true
            }
        }
    }

    @Test func testDemoOnlyV1IsRejectedBeforeMissingV2FieldsAreDecoded() throws {
        try withStore { store, directory in
            try store.save(DemoFixtures.snapshot())
            let file = directory.appendingPathComponent("radar-snapshot.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            var json = try #require(object as? [String: Any])
            json["schemaVersion"] = 1
            json.removeValue(forKey: "connectionState")
            json.removeValue(forKey: "syncState")
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            #expect { try store.load() } throws: { error in
                guard case SnapshotStoreError.unsupportedVersion(1) = error else { return false }
                return true
            }
        }
    }

    @Test func centeredV2CacheIsRejected() throws {
        try withStore { store, directory in
            try store.save(DemoFixtures.snapshot())
            let file = directory.appendingPathComponent("radar-snapshot.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json["schemaVersion"] = 2
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            #expect { try store.load() } throws: { error in
                guard case SnapshotStoreError.unsupportedVersion(2) = error else { return false }
                return true
            }
        }
    }

    @Test func testV3RoundTripPreservesSourceTimesAndPartialFailure() throws {
        try withStore { store, _ in
            let now = ISO8601DateFormatter().date(from: "2026-10-30T04:00:00Z")!
            let zone = TimeZone(identifier: "Asia/Shanghai")!
            let sourceTime = now.addingTimeInterval(-8 * 60 * 60)
            let observation = DailyObservation(metric: .hrv, date: now, value: 60,
                                               updatedAt: sourceTime)
            let snapshot = BaselineEngine().snapshot(observations: [observation], for: now,
                                                     timeZone: zone, generatedAt: now,
                                                     outcomes: [.hrv: .syncFailed],
                                                     syncState: .partial, lastAttemptAt: now)
            try store.save(snapshot)
            let loaded = try #require(try store.load())
            #expect(loaded == snapshot)
            #expect(loaded.axes.first { $0.metric == .hrv }?.observedAt == sourceTime)
            #expect(loaded.isStale(at: now))
        }
    }

    @Test func testCurrentValueWithoutSourceDateCannotReplaceValidatedSnapshot() throws {
        try withStore { store, _ in
            let original = DemoFixtures.snapshot()
            try store.save(original)
            let invalidAxis = RadarAxis(metric: .sleepQuality, currentValue: 80,
                                        baselineValue: nil, currentIndex: nil,
                                        baselineIndex: nil, sampleCount: 0, isProvisional: false)
            let invalid = RadarSnapshot(generatedAt: original.generatedAt, day: original.day,
                                        timeZoneIdentifier: original.timeZoneIdentifier,
                                        axes: [invalidAxis] + Array(original.axes.dropFirst()),
                                        isDemo: false)
            #expect(throws: SnapshotStoreError.self) { try store.save(invalid) }
            #expect(try store.load()?.isDemo == true)
        }
    }

    @Test func testConcurrentReadersNeverSeePartialJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        try store.save(DemoFixtures.snapshot())
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<30 { try store.save(DemoFixtures.snapshot()) }
            }
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<50 {
                        let snapshot = try store.load()
                        guard snapshot?.axes.count == 5 else { throw SnapshotStoreError.invalidSnapshot }
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
