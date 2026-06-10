import Foundation

/// Aggregates UsageRecords into per-window UsageStats and breakdowns.
public struct UsageAggregator: Sendable {
    public struct DailyPoint: Equatable, Sendable {
        public let date: Date
        public let aiCredits: Double
    }

    public struct Snapshot: Equatable, Sendable {
        public var generatedAt: Date
        public var byWindow: [TimeWindow: UsageStats]
        public var byWindowByModel: [TimeWindow: [String: UsageStats]]
        public var byWindowBySource: [TimeWindow: [UsageRecord.Source: UsageStats]]
        /// `nil` key = local, non-nil = remote host nickname.
        public var byWindowByRemote: [TimeWindow: [String?: UsageStats]]
        /// Joint host × source breakdown. Used by the RemotesStrip tooltip
        /// so users can see e.g. "@host → Cloud Agent 211 AIU" instead of
        /// guessing how a per-host total decomposes across sources.
        /// Inner-`nil` host key = local. This is a joint distribution; you
        /// cannot reconstruct it from the marginal `byWindowByRemote` and
        /// `byWindowBySource` aggregates above.
        public var byWindowByRemoteSource: [TimeWindow: [String?: [UsageRecord.Source: UsageStats]]]
        public var dailyCredits: [DailyPoint]

        public static let empty = Snapshot(
            generatedAt: Date(),
            byWindow: [:],
            byWindowByModel: [:],
            byWindowBySource: [:],
            byWindowByRemote: [:],
            byWindowByRemoteSource: [:],
            dailyCredits: []
        )
    }

    public init() {}

    private struct CreditKey: Hashable {
        let sessionId: String
        let source: UsageRecord.Source
        let model: String
        let remoteName: String?

        init(_ record: UsageRecord) {
            self.sessionId = record.sessionId
            self.source = record.source
            self.model = record.model
            self.remoteName = record.remoteName
        }
    }

    public func snapshot(records: [UsageRecord], now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        var byWindow: [TimeWindow: UsageStats] = [:]
        var byWindowByModel: [TimeWindow: [String: UsageStats]] = [:]
        var byWindowBySource: [TimeWindow: [UsageRecord.Source: UsageStats]] = [:]
        var byWindowByRemote: [TimeWindow: [String?: UsageStats]] = [:]
        var byWindowByRemoteSource: [TimeWindow: [String?: [UsageRecord.Source: UsageStats]]] = [:]
        var dailyCredits: [Date: Double] = [:]

        for w in TimeWindow.allCases {
            byWindow[w] = UsageStats.zero
            byWindowByModel[w] = [:]
            byWindowBySource[w] = [:]
            byWindowByRemote[w] = [:]
            byWindowByRemoteSource[w] = [:]
        }

        // AIU is only written to disk at `session.shutdown` (authoritative
        // `totalNanoAiu`). Per-message rows carry only output tokens. A session
        // kept open (e.g. in tmux) accrues messages all day but writes no fresh
        // shutdown, so today's usage has no authoritative AIU yet. To avoid
        // showing ~0 for such sessions we estimate the credits of messages that
        // occurred AFTER the key's last authoritative shutdown ("uncovered"),
        // while messages on/before it stay covered by that shutdown's rollup.
        //
        // Per (session, source, model, remote) key we precompute:
        //   lastAuthoritativeTs — newest authoritative-AIU timestamp
        //   authoritativeAIU    — Σ authoritative AIU
        //   coveredOutputTokens — Σ output tokens of messages on/before that ts
        // and derive a calibrated AIU-per-output-token ratio from the key's own
        // history (token-price estimates ignore input/cache and undercount ~6×).
        var lastAuthoritativeTs: [CreditKey: Date] = [:]
        var authoritativeAIU: [CreditKey: Double] = [:]
        for r in records where r.aiCreditsNano != nil {
            let key = CreditKey(r)
            authoritativeAIU[key, default: 0] += Double(r.aiCreditsNano!) / 1_000_000_000.0
            if let cur = lastAuthoritativeTs[key] {
                if r.timestamp > cur { lastAuthoritativeTs[key] = r.timestamp }
            } else {
                lastAuthoritativeTs[key] = r.timestamp
            }
        }
        var coveredOutputTokens: [CreditKey: Int] = [:]
        for r in records where r.aiCreditsNano == nil && r.requestCount > 0 && r.outputTokens > 0 {
            let key = CreditKey(r)
            if let lastTs = lastAuthoritativeTs[key], r.timestamp <= lastTs {
                coveredOutputTokens[key, default: 0] += r.outputTokens
            }
        }
        // Calibrated, sanity-bounded ratio per key. Require enough covered
        // output to be meaningful; clamp to [output-only rate, 50× output-only]
        // so a tiny denominator can't explode the estimate.
        let minCoveredOutputTokens = 1_000
        var ratioPerKey: [CreditKey: Double] = [:]
        for (key, aiu) in authoritativeAIU {
            guard aiu > 0,
                  let covered = coveredOutputTokens[key], covered >= minCoveredOutputTokens
            else { continue }
            var ratio = aiu / Double(covered)
            if let floorRate = PricingCatalog.outputAiuPerToken(for: key.model) {
                ratio = min(max(ratio, floorRate), floorRate * 50.0)
            }
            ratioPerKey[key] = ratio
        }

        func perRecordCredits(_ r: UsageRecord) -> (credits: Double, authoritative: Bool) {
            if let nano = r.aiCreditsNano {
                return (Double(nano) / 1_000_000_000.0, true)
            }
            // Non-AIU row: only output-bearing message rows can estimate credits.
            guard r.requestCount > 0, r.outputTokens > 0 else { return (0, false) }
            let key = CreditKey(r)
            // Covered by an authoritative shutdown that already counts it.
            if let lastTs = lastAuthoritativeTs[key], r.timestamp <= lastTs {
                return (0, false)
            }
            // Uncovered (in-progress) → calibrated estimate, else token-price.
            if let ratio = ratioPerKey[key] {
                return (Double(r.outputTokens) * ratio, false)
            }
            return (PricingCatalog.estimatedCost(for: r) * 100.0, false)
        }

        for r in records {
            let (credits, authoritative) = perRecordCredits(r)
            let dayStart = calendar.startOfDay(for: r.timestamp)
            dailyCredits[dayStart, default: 0] += credits

            // For per-model breakdown, prefix remote-hosted records with @host
            // so users can see at a glance which usage came from where.
            let modelKey = r.remoteName.map { "\(r.model) @\($0)" } ?? r.model

            for w in TimeWindow.allCases where w.contains(r.timestamp, now: now) {
                byWindow[w]!.add(r, credits: credits, isAuthoritative: authoritative)
                byWindowByModel[w]![modelKey, default: .zero].add(r, credits: credits, isAuthoritative: authoritative)
                byWindowBySource[w]![r.source, default: .zero].add(r, credits: credits, isAuthoritative: authoritative)
                byWindowByRemote[w]![r.remoteName, default: .zero].add(r, credits: credits, isAuthoritative: authoritative)
                byWindowByRemoteSource[w]![r.remoteName, default: [:]][r.source, default: .zero].add(r, credits: credits, isAuthoritative: authoritative)
            }
        }

        let startOfToday = calendar.startOfDay(for: now)
        var sparkline: [DailyPoint] = []
        for i in (0..<30).reversed() {
            if let d = calendar.date(byAdding: .day, value: -i, to: startOfToday) {
                sparkline.append(DailyPoint(
                    date: d,
                    aiCredits: dailyCredits[d, default: 0]
                ))
            }
        }

        return Snapshot(
            generatedAt: now,
            byWindow: byWindow,
            byWindowByModel: byWindowByModel,
            byWindowBySource: byWindowBySource,
            byWindowByRemote: byWindowByRemote,
            byWindowByRemoteSource: byWindowByRemoteSource,
            dailyCredits: sparkline
        )
    }
}
