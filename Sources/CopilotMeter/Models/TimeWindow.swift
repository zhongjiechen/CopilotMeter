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
    public var outputTokens: Int = 0
    public var inputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheWriteTokens: Int = 0
    /// Best-effort retail-equivalent USD cost, computed per-record using
    /// PricingCatalog and the record's model. Tokens with unknown model
    /// contribute 0.
    public var estimatedRetailUsd: Double = 0
    /// **GitHub AI Credits** consumed in this window. Built primarily from
    /// the authoritative `totalNanoAiu` stamped onto session-shutdown rollup
    /// rows by the newer CLI (since the 2026-06-01 billing change);
    /// per-record token-based estimates fill in for rows from older CLIs
    /// that didn't emit AIU. 1 AI Credit = $0.01 USD.
    public var aiCredits: Double = 0
    /// Number of records for which we used the authoritative `totalNanoAiu`
    /// from the CLI vs. a token-based fallback. Used purely for diagnostics
    /// / debug builds; not surfaced in the UI.
    public var aiCreditsAuthoritativeRows: Int = 0

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

    /// USD equivalent of `aiCredits` (1 AI Credit = $0.01).
    public var aiCreditsUsd: Double { aiCredits * 0.01 }

    public mutating func add(_ r: UsageRecord, credits: Double, isAuthoritative: Bool) {
        outputTokens += r.outputTokens
        inputTokens += r.inputTokens
        cacheReadTokens += r.cacheReadTokens
        cacheWriteTokens += r.cacheWriteTokens
        // `estimatedRetailUsd` stays a pure PricingCatalog figure for the
        // separate "retail USD" display, independent of the AI Credit math.
        estimatedRetailUsd += PricingCatalog.estimatedCost(for: r)
        aiCredits += credits
        if isAuthoritative { aiCreditsAuthoritativeRows += 1 }
    }
}
