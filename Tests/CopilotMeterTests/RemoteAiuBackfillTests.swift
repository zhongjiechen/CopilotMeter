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
            model: "gpt-5.5",
            aiCreditsNano: nil
        )
        try cache.insertRecord(withoutAiu, kind: .shutdown)

        let withAiu = shutdownRecord(
            timestamp: timestamp,
            sessionId: "remote-session",
            model: "gpt-5.5",
            aiCreditsNano: 7_000_000_000_000
        )
        try cache.insertRecord(withAiu, kind: .shutdown)

        let smallerAiu = shutdownRecord(
            timestamp: timestamp,
            sessionId: "remote-session",
            model: "gpt-5.5",
            aiCreditsNano: 6_000_000_000_000
        )
        try cache.insertRecord(smallerAiu, kind: .shutdown)

        let records = try cache.allRecords()
            .filter { $0.sessionId == "remote-session" && $0.remoteName == "l40" }

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.aiCreditsNano, 7_000_000_000_000)
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

    private func shutdownRecord(
        timestamp: Date,
        sessionId: String,
        model: String,
        aiCreditsNano: Int64?
    ) -> UsageRecord {
        UsageRecord(
            timestamp: timestamp,
            sessionId: sessionId,
            messageId: nil,
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
