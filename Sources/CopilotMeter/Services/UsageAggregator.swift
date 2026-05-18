import Foundation

/// Aggregates UsageRecords into per-window UsageStats and breakdowns.
public struct UsageAggregator: Sendable {
    public struct DailyPoint: Equatable, Sendable {
        public let date: Date
        public let requests: Double
    }

    public struct Snapshot: Equatable, Sendable {
        public var generatedAt: Date
        public var byWindow: [TimeWindow: UsageStats]
        public var byWindowByModel: [TimeWindow: [String: UsageStats]]
        public var byWindowBySource: [TimeWindow: [UsageRecord.Source: UsageStats]]
        public var blindChatByWindow: [TimeWindow: Int]
        public var dailyRequests: [DailyPoint]

        public static let empty = Snapshot(
            generatedAt: Date(),
            byWindow: [:],
            byWindowByModel: [:],
            byWindowBySource: [:],
            blindChatByWindow: [:],
            dailyRequests: []
        )
    }

    public init() {}

    public func snapshot(records: [UsageRecord], now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        var byWindow: [TimeWindow: UsageStats] = [:]
        var byWindowByModel: [TimeWindow: [String: UsageStats]] = [:]
        var byWindowBySource: [TimeWindow: [UsageRecord.Source: UsageStats]] = [:]
        var blindChat: [TimeWindow: Int] = [:]
        var dailyTotals: [Date: Double] = [:]

        for w in TimeWindow.allCases {
            byWindow[w] = UsageStats.zero
            byWindowByModel[w] = [:]
            byWindowBySource[w] = [:]
            blindChat[w] = 0
        }

        for r in records {
            let dayStart = calendar.startOfDay(for: r.timestamp)
            dailyTotals[dayStart, default: 0] += r.requestCount

            for w in TimeWindow.allCases where w.contains(r.timestamp, now: now) {
                byWindow[w]!.add(r)
                byWindowByModel[w]![r.model, default: .zero].add(r)
                byWindowBySource[w]![r.source, default: .zero].add(r)
                if r.source == .vscodeChat {
                    blindChat[w]! += Int(r.requestCount)
                }
            }
        }

        let startOfToday = calendar.startOfDay(for: now)
        var sparkline: [DailyPoint] = []
        for i in (0..<30).reversed() {
            if let d = calendar.date(byAdding: .day, value: -i, to: startOfToday) {
                sparkline.append(DailyPoint(date: d, requests: dailyTotals[d, default: 0]))
            }
        }

        return Snapshot(
            generatedAt: now,
            byWindow: byWindow,
            byWindowByModel: byWindowByModel,
            byWindowBySource: byWindowBySource,
            blindChatByWindow: blindChat,
            dailyRequests: sparkline
        )
    }
}
