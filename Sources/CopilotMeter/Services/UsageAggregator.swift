import Foundation

/// Aggregates UsageRecords into per-window UsageStats and breakdowns.
public struct UsageAggregator: Sendable {
    public struct DailyPoint: Equatable, Sendable {
        public let date: Date
        public let requests: Double
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
        /// so users can see e.g. "@host → Cloud Agent 211 AIU, VS Code Chat 10 req"
        /// instead of guessing how a per-host total decomposes across sources.
        /// Inner-`nil` host key = local. This is a joint distribution; you
        /// cannot reconstruct it from the marginal `byWindowByRemote` and
        /// `byWindowBySource` aggregates above.
        public var byWindowByRemoteSource: [TimeWindow: [String?: [UsageRecord.Source: UsageStats]]]
        public var blindChatByWindow: [TimeWindow: Int]
        public var dailyRequests: [DailyPoint]

        public static let empty = Snapshot(
            generatedAt: Date(),
            byWindow: [:],
            byWindowByModel: [:],
            byWindowBySource: [:],
            byWindowByRemote: [:],
            byWindowByRemoteSource: [:],
            blindChatByWindow: [:],
            dailyRequests: []
        )
    }

    public init() {}

    public func snapshot(records: [UsageRecord], now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        var byWindow: [TimeWindow: UsageStats] = [:]
        var byWindowByModel: [TimeWindow: [String: UsageStats]] = [:]
        var byWindowBySource: [TimeWindow: [UsageRecord.Source: UsageStats]] = [:]
        var byWindowByRemote: [TimeWindow: [String?: UsageStats]] = [:]
        var byWindowByRemoteSource: [TimeWindow: [String?: [UsageRecord.Source: UsageStats]]] = [:]
        var blindChat: [TimeWindow: Int] = [:]
        var dailyRequests: [Date: Double] = [:]
        var dailyCredits: [Date: Double] = [:]

        for w in TimeWindow.allCases {
            byWindow[w] = UsageStats.zero
            byWindowByModel[w] = [:]
            byWindowBySource[w] = [:]
            byWindowByRemote[w] = [:]
            byWindowByRemoteSource[w] = [:]
            blindChat[w] = 0
        }

        for r in records {
            let dayStart = calendar.startOfDay(for: r.timestamp)
            dailyRequests[dayStart, default: 0] += r.requestCount
            // Per-record AI Credits: prefer the authoritative CLI value;
            // fall back to PricingCatalog estimate (× 100, since 1 AIU = $0.01).
            let perRecordCredits: Double
            if let nano = r.aiCreditsNano {
                perRecordCredits = Double(nano) / 1_000_000_000.0
            } else {
                perRecordCredits = PricingCatalog.estimatedCost(for: r) * 100.0
            }
            dailyCredits[dayStart, default: 0] += perRecordCredits

            // For per-model breakdown, prefix remote-hosted records with @host
            // so users can see at a glance which usage came from where.
            let modelKey = r.remoteName.map { "\(r.model) @\($0)" } ?? r.model

            for w in TimeWindow.allCases where w.contains(r.timestamp, now: now) {
                byWindow[w]!.add(r)
                byWindowByModel[w]![modelKey, default: .zero].add(r)
                byWindowBySource[w]![r.source, default: .zero].add(r)
                byWindowByRemote[w]![r.remoteName, default: .zero].add(r)
                byWindowByRemoteSource[w]![r.remoteName, default: [:]][r.source, default: .zero].add(r)
                if r.source == .vscodeChat {
                    blindChat[w]! += Int(r.requestCount)
                }
            }
        }

        let startOfToday = calendar.startOfDay(for: now)
        var sparkline: [DailyPoint] = []
        for i in (0..<30).reversed() {
            if let d = calendar.date(byAdding: .day, value: -i, to: startOfToday) {
                sparkline.append(DailyPoint(
                    date: d,
                    requests: dailyRequests[d, default: 0],
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
            blindChatByWindow: blindChat,
            dailyRequests: sparkline
        )
    }
}
