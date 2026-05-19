import Foundation

/// Parses Copilot CLI/Agent `events.jsonl` files into `UsageRecord`s.
///
/// Strategy:
///   - Each `assistant.message` event → one UsageRecord with `requestCount=1` and
///     `outputTokens` set from the event. Other token fields are 0 because the
///     event format does not include per-message input/cache tokens.
///   - Each model entry inside a `session.shutdown` event → one supplementary
///     UsageRecord with `requestCount=0` and `outputTokens=0`, but with
///     `inputTokens`/`cacheRead`/`cacheWrite`/`premiumCost` populated, attributed
///     to the shutdown timestamp. These are session-level rollups we cannot
///     split per-day, but most sessions complete within a single day.
public final class EventsJSONLParser {

    public struct ParseResult {
        public let records: [UsageRecord]
        public let lastByteOffset: Int64
        public let sessionId: String
        /// Last event timestamp seen, if any; for "active session" detection.
        public let lastEventAt: Date?
        /// True when a session.shutdown event was observed.
        public let sessionEnded: Bool
        /// `context.hostType` from session.start, when present. Used by the
        /// caller to classify the session source as Cloud Agent vs CLI etc.
        public let hostType: String?
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public init() {}

    /// Parse one file starting from `fromByteOffset`. Returns new records and the
    /// new byte offset (so callers can resume incrementally).
    /// `remoteName` is propagated onto every produced `UsageRecord` so the UI
    /// can attribute the activity to a specific remote SSH host.
    public func parse(file: URL, fromByteOffset: Int64 = 0, source: UsageRecord.Source, remoteName: String? = nil) throws -> ParseResult {
        let sessionId = file.deletingLastPathComponent().lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return ParseResult(records: [], lastByteOffset: fromByteOffset, sessionId: sessionId, lastEventAt: nil, sessionEnded: false, hostType: nil)
        }
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(max(0, fromByteOffset)))
        let data = (try? handle.readToEnd()) ?? Data()

        var records: [UsageRecord] = []
        var lastEventAt: Date?
        var sessionEnded = false
        // Track the session's selected model so we can fill in records where the
        // per-message event omits "model" (older event-log format).
        var sessionModel: String?
        var hostType: String?

        // Split on newlines; tolerate a trailing partial line (don't advance past it).
        var consumedBytesInChunk: Int64 = 0
        let bytes = [UInt8](data)
        var lineStart = 0
        for i in 0..<bytes.count {
            if bytes[i] == 0x0A { // newline
                let lineBytes = Data(bytes[lineStart..<i])
                consumedBytesInChunk = Int64(i + 1)
                lineStart = i + 1
                guard !lineBytes.isEmpty else { continue }
                if let parsed = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any] {
                    if let r = handleEvent(parsed, sessionId: sessionId, source: source, remoteName: remoteName, sessionModel: &sessionModel, hostType: &hostType, lastEventAt: &lastEventAt) {
                        records.append(contentsOf: r.records)
                        if r.shutdown { sessionEnded = true }
                    }
                }
            }
        }

        let newOffset = fromByteOffset + consumedBytesInChunk
        return ParseResult(
            records: records,
            lastByteOffset: newOffset,
            sessionId: sessionId,
            lastEventAt: lastEventAt,
            sessionEnded: sessionEnded,
            hostType: hostType
        )
    }

    private struct EventOutcome {
        let records: [UsageRecord]
        let shutdown: Bool
    }

    private func handleEvent(
        _ evt: [String: Any],
        sessionId: String,
        source: UsageRecord.Source,
        remoteName: String?,
        sessionModel: inout String?,
        hostType: inout String?,
        lastEventAt: inout Date?
    ) -> EventOutcome? {
        guard let type = evt["type"] as? String else { return nil }
        let tsString = evt["timestamp"] as? String
        let ts = tsString.flatMap(parseTimestamp(_:)) ?? Date()
        lastEventAt = ts

        switch type {
        case "session.start":
            if let data = evt["data"] as? [String: Any] {
                if let m = data["selectedModel"] as? String, !m.isEmpty {
                    sessionModel = m
                }
                if let ctx = data["context"] as? [String: Any],
                   let ht = ctx["hostType"] as? String, !ht.isEmpty {
                    hostType = ht
                }
            }
            return nil

        case "assistant.message":
            guard let data = evt["data"] as? [String: Any] else { return nil }
            let model = (data["model"] as? String) ?? sessionModel ?? "unknown"
            let outputTokens = (data["outputTokens"] as? Int) ?? 0
            let messageId = data["messageId"] as? String
            let rec = UsageRecord(
                timestamp: ts,
                sessionId: sessionId,
                messageId: messageId,
                source: source,
                model: model,
                outputTokens: outputTokens,
                inputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                requestCount: 1,
                premiumCost: nil,
                remoteName: remoteName
            )
            return EventOutcome(records: [rec], shutdown: false)

        case "session.shutdown":
            guard let data = evt["data"] as? [String: Any],
                  let modelMetrics = data["modelMetrics"] as? [String: Any] else {
                return EventOutcome(records: [], shutdown: true)
            }
            var rows: [UsageRecord] = []
            for (model, raw) in modelMetrics {
                guard let m = raw as? [String: Any] else { continue }
                let usage = (m["usage"] as? [String: Any]) ?? [:]
                let requests = (m["requests"] as? [String: Any]) ?? [:]
                let input = (usage["inputTokens"] as? Int) ?? 0
                let cacheRead = (usage["cacheReadTokens"] as? Int) ?? 0
                let cacheWrite = (usage["cacheWriteTokens"] as? Int) ?? 0
                let cost = (requests["cost"] as? Double) ?? Double((requests["cost"] as? Int) ?? 0)
                if input == 0 && cacheRead == 0 && cacheWrite == 0 && cost == 0 { continue }
                rows.append(UsageRecord(
                    timestamp: ts,
                    sessionId: sessionId,
                    messageId: nil,
                    source: source,
                    model: model,
                    outputTokens: 0,
                    inputTokens: input,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    requestCount: 0,
                    premiumCost: cost,
                    remoteName: remoteName
                ))
            }
            return EventOutcome(records: rows, shutdown: true)

        default:
            return nil
        }
    }

    private func parseTimestamp(_ s: String) -> Date? {
        if let d = EventsJSONLParser.iso8601.date(from: s) { return d }
        return EventsJSONLParser.iso8601NoFrac.date(from: s)
    }
}
