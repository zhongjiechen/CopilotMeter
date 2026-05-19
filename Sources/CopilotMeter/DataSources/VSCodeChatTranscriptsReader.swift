import Foundation

/// Reads VS Code Copilot Chat **workspace transcripts** — JSONL files written
/// in real time by the Copilot Chat extension when used in agent mode.
///
/// Path layout:
///   <vscode-user-data>/workspaceStorage/<workspaceHash>/GitHub.copilot-chat/
///     transcripts/<sessionId>.jsonl
///
/// These transcripts are the source of truth for chat activity in modern
/// Copilot Chat versions (≥0.47). The central `globalStorage/github.copilot-chat/
/// session-store.db` is only a partial mirror — on remote (SSH) hosts it can be
/// missing the majority of sessions.
///
/// We count one request per `user.message` event. Token data is not available
/// (the transcripts only record event IDs, timestamps, and content), so each
/// emitted `UsageRecord` has `outputTokens=0` and `requestCount=1`.
///
/// **Privacy**: this reader DELIBERATELY does not read or store
/// `data.content` from `user.message` events. Only the event type, the event
/// UUID (`id`), and timestamps enter memory; the prompt text is never
/// inspected.
public final class VSCodeChatTranscriptsReader {

    /// Default user-data root for VS Code Stable on macOS.
    public static var defaultLocalRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Code/User/workspaceStorage"
    }

    private let rootDir: String
    private let cache: CacheStore

    public init(rootDir: String = VSCodeChatTranscriptsReader.defaultLocalRoot,
                cache: CacheStore) {
        self.rootDir = rootDir
        self.cache = cache
    }

    /// Scans every `transcripts/*.jsonl` under `<rootDir>/*/GitHub.copilot-chat/`.
    /// Returns the number of new UsageRecords inserted (for diagnostics).
    @discardableResult
    public func ingest(remoteName: String? = nil) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDir) else { return 0 }

        // Enumerate workspace dirs. We don't recurse arbitrarily deep — only
        // <root>/<wkHash>/GitHub.copilot-chat/transcripts/*.jsonl.
        let workspaces = (try? fm.contentsOfDirectory(atPath: rootDir)) ?? []
        var inserted = 0
        for wkh in workspaces {
            let txDir = URL(fileURLWithPath: rootDir)
                .appendingPathComponent(wkh)
                .appendingPathComponent("GitHub.copilot-chat")
                .appendingPathComponent("transcripts")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: txDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }

            let entries = (try? fm.contentsOfDirectory(at: txDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                guard entry.pathExtension == "jsonl" else { continue }
                let sessionId = entry.deletingPathExtension().lastPathComponent
                inserted += try ingestOne(file: entry, sessionId: sessionId, remoteName: remoteName)
            }
        }
        return inserted
    }

    private func ingestOne(file: URL, sessionId: String, remoteName: String?) throws -> Int {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        var resumeFrom: Int64 = 0
        if let state = try cache.fileState(filePath: file.path) {
            resumeFrom = state.byteOffset
        }
        // File rotation / truncation: reset to 0 if recorded offset overshoots.
        if resumeFrom > size { resumeFrom = 0 }
        if resumeFrom >= size {
            return 0
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(resumeFrom))
        let data = (try? handle.readToEnd()) ?? Data()
        if data.isEmpty { return 0 }

        // Two-pass parse:
        //   pass 1 — scan the chunk for any `tool.execution_start` so we
        //            classify this session as Agent vs Chat for THIS run
        //   pass 2 — emit user.message records with the correct source
        // If the session was already classified Agent in earlier runs, we
        // also need to honor that, so we also retroactively reclassify any
        // prior `.vscodeChat` rows below.
        var sawToolCall = false
        var userMessages: [(messageId: String, ts: Date)] = []
        var consumed: Int64 = 0
        var lastEventAt: Date?

        let bytes = [UInt8](data)
        var lineStart = 0
        for i in 0..<bytes.count {
            guard bytes[i] == 0x0A else { continue }
            let lineBytes = Data(bytes[lineStart..<i])
            consumed = Int64(i + 1)
            lineStart = i + 1
            guard !lineBytes.isEmpty,
                  let evt = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any]
            else { continue }
            let etype = evt["type"] as? String
            if etype == "tool.execution_start" {
                sawToolCall = true
                continue
            }
            if etype != "user.message" { continue }
            guard let mid = evt["id"] as? String, !mid.isEmpty else { continue }
            let ts = Self.parseTimestamp(evt["timestamp"] as? String) ?? Date()
            lastEventAt = ts
            userMessages.append((messageId: mid, ts: ts))
        }

        let source: UsageRecord.Source = sawToolCall ? .vscodeAgent : .vscodeChat
        var inserted = 0
        for um in userMessages {
            let rec = UsageRecord(
                timestamp: um.ts,
                sessionId: sessionId,
                messageId: um.messageId,
                source: source,
                model: "GitHub Copilot Chat",
                outputTokens: 0,
                inputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                requestCount: 1,
                premiumCost: nil,
                remoteName: remoteName
            )
            try cache.insertRecord(rec, kind: .message)
            inserted += 1
        }

        // Retroactively reclassify any previously-ingested .vscodeChat rows
        // for this session if we now know it was Agent mode.
        if sawToolCall {
            try cache.reclassifyTranscriptChatAsAgent(
                sessionIds: [sessionId],
                remoteName: remoteName
            )
        }

        try cache.updateFileState(
            filePath: file.path,
            sessionId: sessionId,
            byteOffset: resumeFrom + consumed,
            sessionEnded: false,
            lastEventAt: lastEventAt
        )
        return inserted
    }

    private static let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso8601Frac.date(from: s) ?? iso8601.date(from: s)
    }
}
