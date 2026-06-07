import Foundation
import XCTest
@testable import CopilotMeter

final class RemoteAiuBackfillTests: XCTestCase {
    func testExistingRemoteShutdownRowBackfillsAiCreditsNano() throws {
        let temp = try temporaryDirectory()
        let cache = try CacheStore(path: temp.appendingPathComponent("cache.db").path)
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)

        let withoutAiu = shutdownRecord(
            timestamp: timestamp,
            sessionId: "remote-session",
            messageId: "shutdown:100",
            model: "gpt-5.5",
            aiCreditsNano: nil
        )
        try cache.insertRecord(withoutAiu, kind: .shutdown)

        let withAiu = shutdownRecord(
            timestamp: timestamp,
            sessionId: "remote-session",
            messageId: "shutdown:100",
            model: "gpt-5.5",
            aiCreditsNano: 7_000_000_000_000
        )
        try cache.insertRecord(withAiu, kind: .shutdown)

        let smallerAiu = shutdownRecord(
            timestamp: timestamp,
            sessionId: "remote-session",
            messageId: "shutdown:100",
            model: "gpt-5.5",
            aiCreditsNano: 6_000_000_000_000
        )
        try cache.insertRecord(smallerAiu, kind: .shutdown)

        let records = try cache.allRecords()
            .filter { $0.sessionId == "remote-session" && $0.remoteName == "l40" }

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.aiCreditsNano, 7_000_000_000_000)
    }

    func testMultipleShutdownEventsInSameSessionAreDistinctAndIdempotent() throws {
        let temp = try temporaryDirectory()
        let cache = try CacheStore(path: temp.appendingPathComponent("cache.db").path)
        let sessionDir = temp.appendingPathComponent("session-a")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        let lines = [
            #"{"type":"session.start","timestamp":"2026-06-07T09:00:00.000Z","data":{"selectedModel":"gpt-5.5"}}"#,
            #"{"type":"session.shutdown","timestamp":"2026-06-07T09:10:00.000Z","data":{"modelMetrics":{"gpt-5.5":{"usage":{"inputTokens":1000,"outputTokens":100,"cacheReadTokens":900,"cacheWriteTokens":0},"requests":{"cost":0},"totalNanoAiu":10000000000}}}}"#,
            #"{"type":"session.shutdown","timestamp":"2026-06-07T09:20:00.000Z","data":{"modelMetrics":{"gpt-5.5":{"usage":{"inputTokens":2000,"outputTokens":200,"cacheReadTokens":1800,"cacheWriteTokens":0},"requests":{"cost":0},"totalNanoAiu":20000000000}}}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: eventsFile)

        let parser = EventsJSONLParser()
        let firstParse = try parser.parse(file: eventsFile, source: .copilotCLI, remoteName: "l40")
        let secondParse = try parser.parse(file: eventsFile, source: .copilotCLI, remoteName: "l40")

        for record in firstParse.records + secondParse.records {
            try cache.insertRecord(record, kind: .shutdown)
        }

        let records = try cache.allRecords()
            .filter { $0.sessionId == "session-a" && $0.remoteName == "l40" }
        let messageIds = Set(records.compactMap(\.messageId))

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(messageIds.count, 2)
        XCTAssertEqual(records.reduce(0) { $0 + ($1.aiCreditsNano ?? 0) }, 30_000_000_000)
        XCTAssertEqual(records.reduce(0) { $0 + $1.inputTokens }, 3_000)
        XCTAssertEqual(records.reduce(0) { $0 + $1.cacheReadTokens }, 2_700)

        let snapshot = UsageAggregator().snapshot(
            records: records,
            now: ISO8601DateFormatter().date(from: "2026-06-07T12:00:00Z")!
        )
        let stats = snapshot.byWindow[.today] ?? .zero
        XCTAssertEqual(stats.aiCredits, 30, accuracy: 0.0001)
        XCTAssertEqual(stats.cacheHitRate ?? 0, 0.9, accuracy: 0.0001)
    }

    func testMessageOutputEstimateDoesNotDoubleCountAuthoritativeShutdownAiu() throws {
        let timestamp = ISO8601DateFormatter().date(from: "2026-06-07T09:10:00Z")!
        let message = UsageRecord(
            timestamp: timestamp,
            sessionId: "session-with-aiu",
            messageId: "message-1",
            source: .copilotCLI,
            model: "gpt-5.5",
            outputTokens: 1_000_000,
            inputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            requestCount: 1,
            premiumCost: nil
        )
        let shutdown = UsageRecord(
            timestamp: timestamp,
            sessionId: "session-with-aiu",
            messageId: "shutdown:42",
            source: .copilotCLI,
            model: "gpt-5.5",
            outputTokens: 0,
            inputTokens: 10_000,
            cacheReadTokens: 9_000,
            cacheWriteTokens: 0,
            requestCount: 0,
            premiumCost: nil,
            aiCreditsNano: 10_000_000_000
        )

        let snapshot = UsageAggregator().snapshot(
            records: [message, shutdown],
            now: ISO8601DateFormatter().date(from: "2026-06-07T12:00:00Z")!
        )

        XCTAssertEqual(snapshot.byWindow[.today]?.aiCredits ?? 0, 10, accuracy: 0.0001)
        XCTAssertGreaterThan(snapshot.byWindow[.today]?.estimatedRetailUsd ?? 0, 0)
    }

    func testGithubHostedSessionWithCliResumeClassifiesAsCLI() {
        XCTAssertEqual(
            RefreshWorker.classifySession(
                hostType: "github",
                isVSCodeSession: false,
                hasCliResume: true,
                existingSource: nil
            ),
            .copilotCLI
        )
    }

    func testCliResumeWinsOverVSCodeDbPresence() {
        XCTAssertEqual(
            RefreshWorker.classifySession(
                hostType: "github",
                isVSCodeSession: true,
                hasCliResume: true,
                existingSource: nil
            ),
            .copilotCLI
        )
    }

    func testGithubHostedSessionWithoutCliResumeClassifiesAsCloudAgent() {
        XCTAssertEqual(
            RefreshWorker.classifySession(
                hostType: "github",
                isVSCodeSession: false,
                hasCliResume: false,
                existingSource: nil
            ),
            .codingAgent
        )
    }

    func testExistingCliClassificationPersistsWhenIncrementalChunkHasNoResumeMarker() {
        XCTAssertEqual(
            RefreshWorker.classifySession(
                hostType: "github",
                isVSCodeSession: false,
                hasCliResume: false,
                existingSource: .copilotCLI
            ),
            .copilotCLI
        )
    }

    func testRemoteAiuBackfillDeletesOffsetsExactlyOnce() throws {
        let temp = try temporaryDirectory()
        let cache = try CacheStore(path: temp.appendingPathComponent("cache.db").path)
        let remotesRoot = temp.appendingPathComponent("remotes")
        let l40Offsets = remotesRoot
            .appendingPathComponent("l40")
            .appendingPathComponent("offsets.json")
        let gh200Offsets = remotesRoot
            .appendingPathComponent("gh200_0")
            .appendingPathComponent("offsets.json")

        try FileManager.default.createDirectory(
            at: l40Offsets.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: gh200Offsets.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"session-a":123}"#.utf8).write(to: l40Offsets)
        try Data(#"{"session-b":456}"#.utf8).write(to: gh200Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForAiuBackfillIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: l40Offsets.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gh200Offsets.path))
        XCTAssertTrue(cache.migrationDone(RefreshWorker.remoteAiuBackfillKey))

        try Data(#"{"session-a":789}"#.utf8).write(to: l40Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForAiuBackfillIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: l40Offsets.path))
    }

    func testShutdownEventIdMigrationDeletesOffsetsExactlyOnce() throws {
        let temp = try temporaryDirectory()
        let cache = try CacheStore(path: temp.appendingPathComponent("cache.db").path)
        let remotesRoot = temp.appendingPathComponent("remotes")
        let l40Offsets = remotesRoot
            .appendingPathComponent("l40")
            .appendingPathComponent("offsets.json")

        try FileManager.default.createDirectory(
            at: l40Offsets.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"session-a":123}"#.utf8).write(to: l40Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForShutdownEventIdsIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: l40Offsets.path))
        XCTAssertTrue(cache.migrationDone(RefreshWorker.shutdownEventIdRemoteResetKey))

        try Data(#"{"session-a":789}"#.utf8).write(to: l40Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForShutdownEventIdsIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: l40Offsets.path))
    }

    func testCliResumeClassificationDeletesOffsetsExactlyOnce() throws {
        let temp = try temporaryDirectory()
        let cache = try CacheStore(path: temp.appendingPathComponent("cache.db").path)
        let remotesRoot = temp.appendingPathComponent("remotes")
        let l40Offsets = remotesRoot
            .appendingPathComponent("l40")
            .appendingPathComponent("offsets.json")

        try FileManager.default.createDirectory(
            at: l40Offsets.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"session-a":123}"#.utf8).write(to: l40Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForCliResumeClassificationIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: l40Offsets.path))
        XCTAssertTrue(cache.migrationDone(RefreshWorker.cliResumeClassificationRemoteResetKey))

        try Data(#"{"session-a":789}"#.utf8).write(to: l40Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForCliResumeClassificationIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: l40Offsets.path))
    }

    func testCliResumePrecedenceDeletesOffsetsExactlyOnce() throws {
        let temp = try temporaryDirectory()
        let cache = try CacheStore(path: temp.appendingPathComponent("cache.db").path)
        let remotesRoot = temp.appendingPathComponent("remotes")
        let l40Offsets = remotesRoot
            .appendingPathComponent("l40")
            .appendingPathComponent("offsets.json")

        try FileManager.default.createDirectory(
            at: l40Offsets.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"session-a":123}"#.utf8).write(to: l40Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForCliResumePrecedenceIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: l40Offsets.path))
        XCTAssertTrue(cache.migrationDone(RefreshWorker.cliResumePrecedenceRemoteResetKey))

        try Data(#"{"session-a":789}"#.utf8).write(to: l40Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForCliResumePrecedenceIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: l40Offsets.path))
    }

    private func shutdownRecord(
        timestamp: Date,
        sessionId: String,
        messageId: String,
        model: String,
        aiCreditsNano: Int64?
    ) -> UsageRecord {
        UsageRecord(
            timestamp: timestamp,
            sessionId: sessionId,
            messageId: messageId,
            source: .copilotCLI,
            model: model,
            outputTokens: 0,
            inputTokens: 1_000,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            requestCount: 0,
            premiumCost: nil,
            aiCreditsNano: aiCreditsNano,
            remoteName: "l40"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotMeterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
