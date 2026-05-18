import Foundation

public enum TimeWindow: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case all

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .all: return "All"
        }
    }

    /// Returns the inclusive lower bound for membership tests. `nil` means "no bound".
    public func lowerBound(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            // Rolling 7 days, anchored at start of today
            let startOfToday = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -6, to: startOfToday)
        case .month:
            // Rolling 30 days
            let startOfToday = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -29, to: startOfToday)
        case .all:
            return nil
        }
    }

    public func contains(_ date: Date, now: Date = Date()) -> Bool {
        guard let lb = lowerBound(now: now) else { return true }
        return date >= lb
    }
}

/// Aggregated metrics for a time window or model bucket.
public struct UsageStats: Equatable, Sendable {
    public var requests: Double = 0
    public var outputTokens: Int = 0
    public var inputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheWriteTokens: Int = 0
    public var premiumCost: Double = 0
    /// Interactions where we don't have token data (e.g., VS Code Chat)
    public var blindInteractions: Int = 0

    public static let zero = UsageStats()

    /// % of input tokens that were served from prompt cache, in [0, 1].
    /// Returns nil when we have no input tokens at all (e.g. only chat-mode rows).
    public var cacheHitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return Double(cacheReadTokens) / Double(inputTokens)
    }

    /// Tokens that had to be re-processed from scratch (the "miss" portion).
    public var freshInputTokens: Int {
        max(0, inputTokens - cacheReadTokens)
    }

    public mutating func add(_ r: UsageRecord) {
        requests += r.requestCount
        outputTokens += r.outputTokens
        inputTokens += r.inputTokens
        cacheReadTokens += r.cacheReadTokens
        cacheWriteTokens += r.cacheWriteTokens
        if let c = r.premiumCost { premiumCost += c }
    }
}
