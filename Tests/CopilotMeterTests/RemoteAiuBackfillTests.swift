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

    func testInProgressMessagesAfterLastShutdownAreEstimatedIntoToday() {
        let now = Date()
        let yesterdayShutdownTs = now.addingTimeInterval(-30 * 3600)
        let coveredMsgTs = now.addingTimeInterval(-31 * 3600)   // before the shutdown
        let todayMsgTs = now.addingTimeInterval(-3600)          // after, in-progress today

        func msg(_ ts: Date, output: Int) -> UsageRecord {
            UsageRecord(timestamp: ts, sessionId: "tmux", messageId: "m\(ts.timeIntervalSince1970)",
                        source: .copilotCLI, model: "gpt-5.5", outputTokens: output,
                        inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                        requestCount: 1, premiumCost: nil, remoteName: "l40")
        }
        let shutdown = UsageRecord(
            timestamp: yesterdayShutdownTs, sessionId: "tmux", messageId: "shutdown:1",
            source: .copilotCLI, model: "gpt-5.5", outputTokens: 0,
            inputTokens: 100_000, cacheReadTokens: 90_000, cacheWriteTokens: 0,
            requestCount: 0, premiumCost: nil, aiCreditsNano: 10_000_000_000, remoteName: "l40")

        let records = [shutdown, msg(coveredMsgTs, output: 2_000), msg(todayMsgTs, output: 500)]
        let snap = UsageAggregator().snapshot(records: records, now: now)

        // ratio = 10 AIU / 2000 covered output tokens = 0.005 AIU/token.
        // Today only contains the uncovered message → 500 × 0.005 = 2.5 AIU.
        XCTAssertEqual(snap.byWindow[.today]?.aiCredits ?? 0, 2.5, accuracy: 0.01)
        // Month = authoritative 10 + covered 0 + today estimate 2.5 = 12.5.
        XCTAssertEqual(snap.byWindow[.month]?.aiCredits ?? 0, 12.5, accuracy: 0.01)
    }

    func testMessagesCoveredByShutdownDoNotDoubleCount() {
        let now = Date()
        let shutdownTs = now.addingTimeInterval(-3600)
        let coveredMsgTs = now.addingTimeInterval(-7200)   // before shutdown → covered
        let shutdown = UsageRecord(
            timestamp: shutdownTs, sessionId: "s", messageId: "shutdown:1",
            source: .copilotCLI, model: "gpt-5.5", outputTokens: 0,
            inputTokens: 10_000, cacheReadTokens: 9_000, cacheWriteTokens: 0,
            requestCount: 0, premiumCost: nil, aiCreditsNano: 10_000_000_000, remoteName: "l40")
        let coveredMsg = UsageRecord(
            timestamp: coveredMsgTs, sessionId: "s", messageId: "m1",
            source: .copilotCLI, model: "gpt-5.5", outputTokens: 1_000_000,
            inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            requestCount: 1, premiumCost: nil, remoteName: "l40")
        let snap = UsageAggregator().snapshot(records: [shutdown, coveredMsg], now: now)
        // Only the authoritative 10 AIU; the covered message adds nothing.
        XCTAssertEqual(snap.byWindow[.today]?.aiCredits ?? 0, 10, accuracy: 0.0001)
    }

    func testSessionWithNoShutdownFallsBackToTokenEstimate() {
        let now = Date()
        let msg = UsageRecord(
            timestamp: now.addingTimeInterval(-600), sessionId: "fresh", messageId: "m1",
            source: .copilotCLI, model: "gpt-5.5", outputTokens: 1_000_000,
            inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            requestCount: 1, premiumCost: nil, remoteName: "l40")
        let snap = UsageAggregator().snapshot(records: [msg], now: now)
        // No authoritative history → PricingCatalog output estimate ($30/M ×100).
        XCTAssertEqual(snap.byWindow[.today]?.aiCredits ?? 0, 3000, accuracy: 1.0)
    }

    func testSessionStateGithubSessionClassifiesAsCLINotCloudAgent() {
        // hostType=github is no longer a Cloud Agent signal: a session in
        // session-state was run by copilot on the machine = terminal CLI.
        XCTAssertEqual(
            RefreshWorker.classifySession(isVSCodeSession: false),
            .copilotCLI
        )
    }

    func testGenuineVSCodeSessionClassifiesAsVSCodeAgent() {
        XCTAssertEqual(
            RefreshWorker.classifySession(isVSCodeSession: true),
            .vscodeAgent
        )
    }

    func testStickyVSCodeMembershipSurvivesDbUnavailability() throws {
        let temp = try temporaryDirectory()
        let cache = try CacheStore(path: temp.appendingPathComponent("cache.db").path)

        // A sync that successfully read the VS Code DB marks the session sticky.
        try cache.markVSCodeSession(sessionId: "vs-1", remoteName: "l40")
        XCTAssertTrue(cache.isVSCodeSessionKnown(sessionId: "vs-1", remoteName: "l40"))

        // A later sync where the DB is unavailable (not in the current id set)
        // must still classify it as VS Code Agent via the sticky flag.
        let isVSCodeNow = false || cache.isVSCodeSessionKnown(sessionId: "vs-1", remoteName: "l40")
        XCTAssertEqual(RefreshWorker.classifySession(isVSCodeSession: isVSCodeNow), .vscodeAgent)

        // Local vs remote and per-remote isolation.
        XCTAssertFalse(cache.isVSCodeSessionKnown(sessionId: "vs-1", remoteName: nil))
        XCTAssertFalse(cache.isVSCodeSessionKnown(sessionId: "vs-1", remoteName: "gh200_0"))
    }

    func testRetireCodingAgentMigrationFlipsRowsToCLI() throws {
        let temp = try temporaryDirectory()
        let dbPath = temp.appendingPathComponent("cache.db").path
        // Seed a codingAgent row and a vscodeAgent row using a first CacheStore,
        // then reopen to trigger the migration on init.
        do {
            let cache = try CacheStore(path: dbPath)
            try cache.insertRecord(
                UsageRecord(
                    timestamp: Date(timeIntervalSince1970: 1_780_000_000),
                    sessionId: "cloud-1", messageId: "shutdown:1",
                    source: .codingAgent, model: "gpt-5.5",
                    outputTokens: 0, inputTokens: 1000, cacheReadTokens: 0,
                    cacheWriteTokens: 0, requestCount: 0, premiumCost: nil,
                    aiCreditsNano: 5_000_000_000, remoteName: "l40"
                ), kind: .shutdown)
            try cache.insertRecord(
                UsageRecord(
                    timestamp: Date(timeIntervalSince1970: 1_780_000_000),
                    sessionId: "vs-1", messageId: "m1",
                    source: .vscodeAgent, model: "GitHub Copilot Chat",
                    outputTokens: 0, inputTokens: 0, cacheReadTokens: 0,
                    cacheWriteTokens: 0, requestCount: 1, premiumCost: nil,
                    remoteName: "l40"
                ), kind: .message)
            // Simulate a pre-v031 cache by clearing the migration flag.
            try SQLite(path: dbPath, readOnly: false)
                .execute("DELETE FROM schema_meta WHERE key = ?",
                         bindings: ["v031_retire_coding_agent_cache"])
        }

        // Reopen → migration runs.
        let cache = try CacheStore(path: dbPath)
        let records = try cache.allRecords()
        let cloud = records.first { $0.sessionId == "cloud-1" }
        let vs = records.first { $0.sessionId == "vs-1" }
        XCTAssertEqual(cloud?.source, .copilotCLI)       // codingAgent → CLI
        XCTAssertEqual(vs?.source, .vscodeAgent)         // vscodeAgent untouched
        // vscodeAgent row seeded into the sticky table.
        XCTAssertTrue(cache.isVSCodeSessionKnown(sessionId: "vs-1", remoteName: "l40"))
    }

    func testKnownSessionIdsExcludesCopilotcli() throws {
        let temp = try temporaryDirectory()
        let dbPath = temp.appendingPathComponent("session-store.db").path
        let db = try SQLite(path: dbPath, readOnly: false)
        try db.exec("""
            CREATE TABLE sessions (
                id TEXT, agent_name TEXT, host_type TEXT
            );
        """)
        try db.execute("INSERT INTO sessions (id, agent_name, host_type) VALUES (?, ?, ?)",
                       bindings: ["vscode-1", "GitHub Copilot Chat", "vscode"])
        try db.execute("INSERT INTO sessions (id, agent_name, host_type) VALUES (?, ?, ?)",
                       bindings: ["cli-1", "copilotcli", "vscode"])
        try db.execute("INSERT INTO sessions (id, agent_name, host_type) VALUES (?, ?, ?)",
                       bindings: ["cli-2", " CopilotCLI ", "vscode"])

        let ids = VSCodeChatReader(path: dbPath).knownSessionIds()
        XCTAssertTrue(ids.contains("vscode-1"))
        XCTAssertFalse(ids.contains("cli-1"))
        XCTAssertFalse(ids.contains("cli-2"))
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

    func testPersistentResumeMigrationDeletesOffsetsExactlyOnce() throws {
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

        try RefreshWorker.resetRemoteExtractorOffsetsForPersistentResumeIfNeeded(
            cache: cache,
            remotesRoot: remotesRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: l40Offsets.path))
        XCTAssertTrue(cache.migrationDone(RefreshWorker.persistentResumeRemoteResetKey))

        try Data(#"{"session-a":789}"#.utf8).write(to: l40Offsets)

        try RefreshWorker.resetRemoteExtractorOffsetsForPersistentResumeIfNeeded(
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
