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

        let authoritativeCreditKeys = Set(records.compactMap { record -> CreditKey? in
            record.aiCreditsNano == nil ? nil : CreditKey(record)
        })

        for r in records {
            let includeEstimatedAiCredits = !(r.requestCount > 0 && authoritativeCreditKeys.contains(CreditKey(r)))
            let dayStart = calendar.startOfDay(for: r.timestamp)
            // Per-record AI Credits: prefer the authoritative CLI value;
            // fall back to PricingCatalog estimate (× 100, since 1 AIU = $0.01).
            let perRecordCredits: Double
            if let nano = r.aiCreditsNano {
                perRecordCredits = Double(nano) / 1_000_000_000.0
            } else if includeEstimatedAiCredits {
                perRecordCredits = PricingCatalog.estimatedCost(for: r) * 100.0
            } else {
                perRecordCredits = 0
            }
            dailyCredits[dayStart, default: 0] += perRecordCredits

            // For per-model breakdown, prefix remote-hosted records with @host
            // so users can see at a glance which usage came from where.
            let modelKey = r.remoteName.map { "\(r.model) @\($0)" } ?? r.model

            for w in TimeWindow.allCases where w.contains(r.timestamp, now: now) {
                byWindow[w]!.add(r, includeEstimatedAiCredits: includeEstimatedAiCredits)
                byWindowByModel[w]![modelKey, default: .zero].add(r, includeEstimatedAiCredits: includeEstimatedAiCredits)
                byWindowBySource[w]![r.source, default: .zero].add(r, includeEstimatedAiCredits: includeEstimatedAiCredits)
                byWindowByRemote[w]![r.remoteName, default: .zero].add(r, includeEstimatedAiCredits: includeEstimatedAiCredits)
                byWindowByRemoteSource[w]![r.remoteName, default: [:]][r.source, default: .zero].add(r, includeEstimatedAiCredits: includeEstimatedAiCredits)
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
