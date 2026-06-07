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
        /// `selectedModel` from session.start, when present. The caller uses
        /// this to backfill records that previously decoded with model="unknown"
        /// (older CLI builds didn't include `model` on per-message events).
        public let selectedModel: String?
        /// True when a `session.resume` event was observed. A GitHub-hosted
        /// session resumed from a terminal is user-driven CLI usage from that
        /// point of view, not a fresh Cloud Agent run.
        public let sessionResumed: Bool
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
            return ParseResult(records: [], lastByteOffset: fromByteOffset, sessionId: sessionId, lastEventAt: nil, sessionEnded: false, hostType: nil, selectedModel: nil, sessionResumed: false)
        }
        defer { try? handle.close() }

        var lastEventAt: Date?
        var sessionEnded = false
        var sessionResumed = false
        // Track the session's selected model so we can fill in records where the
        // per-message event omits "model" (older event-log format).
        var sessionModel: String?
        var hostType: String?

        // Always read line 1 to recover session.start metadata (selectedModel,
        // hostType). For resumed parses (fromByteOffset > 0) the session.start
        // sits before the offset, so without this we'd lose its metadata and
        // every new assistant.message would resolve to model="unknown". Cheap.
        if fromByteOffset > 0 {
            try handle.seek(toOffset: 0)
            if let firstLine = readSingleLine(from: handle),
               let parsed = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any] {
                _ = handleEvent(
                    parsed,
                    sessionId: sessionId,
                    source: source,
                    remoteName: remoteName,
                    eventByteOffset: nil,
                    sessionModel: &sessionModel,
                    hostType: &hostType,
                    sessionResumed: &sessionResumed,
                    lastEventAt: &lastEventAt
                )
            }
        }

        try handle.seek(toOffset: UInt64(max(0, fromByteOffset)))
        let data = (try? handle.readToEnd()) ?? Data()

        var records: [UsageRecord] = []

        // Split on newlines; tolerate a trailing partial line (don't advance past it).
        var consumedBytesInChunk: Int64 = 0
        let bytes = [UInt8](data)
        var lineStart = 0
        for i in 0..<bytes.count {
            if bytes[i] == 0x0A { // newline
                let currentLineStart = lineStart
                let lineBytes = Data(bytes[lineStart..<i])
                consumedBytesInChunk = Int64(i + 1)
                lineStart = i + 1
                guard !lineBytes.isEmpty else { continue }
                if let parsed = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any] {
                    if let r = handleEvent(
                        parsed,
                        sessionId: sessionId,
                        source: source,
                        remoteName: remoteName,
                        eventByteOffset: fromByteOffset + Int64(currentLineStart),
                        sessionModel: &sessionModel,
                        hostType: &hostType,
                        sessionResumed: &sessionResumed,
                        lastEventAt: &lastEventAt
                    ) {
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
            hostType: hostType,
            selectedModel: sessionModel,
            sessionResumed: sessionResumed
        )
    }

    /// Reads bytes from the current offset of `handle` until the first `\n`,
    /// returning the line (excluding the newline). Returns nil on read failure
    /// or empty file.
    private func readSingleLine(from handle: FileHandle) -> Data? {
        // events.jsonl session.start lines are < 2KB in practice.
        let chunk = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let nlIndex = chunk.firstIndex(of: 0x0A) else { return nil }
        return chunk.subdata(in: chunk.startIndex..<nlIndex)
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
        eventByteOffset: Int64?,
        sessionModel: inout String?,
        hostType: inout String?,
        sessionResumed: inout Bool,
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

        case "session.resume":
            sessionResumed = true
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
            guard let eventByteOffset else {
                return EventOutcome(records: [], shutdown: true)
            }
            let shutdownMessageId = UsageRecord.shutdownMessageId(lineOffset: eventByteOffset)
            var rows: [UsageRecord] = []
            for (model, raw) in modelMetrics {
                guard let m = raw as? [String: Any] else { continue }
                let usage = (m["usage"] as? [String: Any]) ?? [:]
                let requests = (m["requests"] as? [String: Any]) ?? [:]
                let input = (usage["inputTokens"] as? Int) ?? 0
                let cacheRead = (usage["cacheReadTokens"] as? Int) ?? 0
                let cacheWrite = (usage["cacheWriteTokens"] as? Int) ?? 0
                let cost = (requests["cost"] as? Double) ?? Double((requests["cost"] as? Int) ?? 0)
                // GitHub's authoritative AI-Credit value (nano-AIU, 1 AIU
                // = $0.01 USD post-2026-06-01). Only present on newer CLI
                // builds; absent rollups still get a token-based estimate
                // downstream via PricingCatalog.
                let aiuNano: Int64?
                if let n = m["totalNanoAiu"] as? Int64 {
                    aiuNano = n
                } else if let n = m["totalNanoAiu"] as? Int {
                    aiuNano = Int64(n)
                } else if let d = m["totalNanoAiu"] as? Double {
                    aiuNano = Int64(d)
                } else {
                    aiuNano = nil
                }
                if input == 0 && cacheRead == 0 && cacheWrite == 0 && cost == 0 && aiuNano == nil { continue }
                rows.append(UsageRecord(
                    timestamp: ts,
                    sessionId: sessionId,
                    messageId: shutdownMessageId,
                    source: source,
                    model: model,
                    outputTokens: 0,
                    inputTokens: input,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    requestCount: 0,
                    premiumCost: cost,
                    aiCreditsNano: aiuNano,
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
