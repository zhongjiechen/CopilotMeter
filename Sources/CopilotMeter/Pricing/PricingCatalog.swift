import Foundation

/// Retail USD pricing per million tokens for a single model.
///
/// All four rates are independent so we can model Anthropic-style cache
/// pricing (read = 10% of input, write = 125% of input) and OpenAI-style
/// (no cache discount, or different ratios).
public struct ModelPrice: Sendable, Equatable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheWritePerMillion: Double

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.inputPerMillion = input
        self.outputPerMillion = output
        // Sensible defaults if a provider doesn't publish cache rates: read is
        // 10% of input (Anthropic convention), write is 125% of input.
        self.cacheReadPerMillion = cacheRead ?? input * 0.10
        self.cacheWritePerMillion = cacheWrite ?? input * 1.25
    }

    /// Cost in USD for the given token counts at this model's rates.
    ///
    /// IMPORTANT: GitHub Copilot's session-shutdown event reports `inputTokens`
    /// as the *total* prompt size, INCLUDING the bytes that were served from
    /// prompt cache (`cacheReadTokens`) and the bytes that were freshly written
    /// to cache (`cacheWriteTokens`). To avoid double-counting, the input-rate
    /// is applied only to the "fresh" portion of the prompt:
    ///
    ///     fresh = max(0, input - cacheRead - cacheWrite)
    ///     total = fresh×inputRate + cacheRead×cacheReadRate
    ///           + cacheWrite×cacheWriteRate + output×outputRate
    ///
    /// This matches Anthropic / OpenAI billing semantics where cache hits are
    /// billed at a steep discount and cache writes carry a small surcharge.
    public func cost(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        let freshInput = max(0, input - cacheRead - cacheWrite)
        let i = Double(freshInput) * inputPerMillion       / 1_000_000.0
        let r = Double(cacheRead)  * cacheReadPerMillion   / 1_000_000.0
        let w = Double(cacheWrite) * cacheWritePerMillion  / 1_000_000.0
        let o = Double(output)     * outputPerMillion      / 1_000_000.0
        return i + r + w + o
    }
}

/// A best-effort lookup table mapping GitHub Copilot's internal model names
/// (e.g. "claude-opus-4.7-1m-internal", "gpt-5.5") to the closest equivalent
/// **public retail** rate from the underlying provider, plus a single rate for
/// GitHub's own "premium request" overage billing.
///
/// These constants ARE approximate. They should be updated when official
/// pricing changes. The values reflect publicly-documented rates as of 2025
/// for Anthropic Claude and OpenAI GPT models; for variants without a
/// published rate (e.g. "-internal" preview models) we use the closest family
/// member.
///
/// Sources you'll want to keep an eye on:
///   - https://www.anthropic.com/pricing
///   - https://openai.com/api/pricing
///   - https://docs.github.com/copilot/managing-copilot/monitoring-usage-and-entitlements/about-premium-requests
public enum PricingCatalog {

    /// GitHub Copilot's per-premium-request overage rate (USD) — applied to
    /// the `requests.cost` field recorded in each session's modelMetrics.
    /// As of 2025, GitHub bills overage premium requests at $0.04 each across
    /// the Pro, Pro+, Business, and Enterprise plans.
    public static let usdPerPremiumRequest: Double = 0.04

    /// Anthropic — Claude 4.x family ($/M tokens).
    private static let claudeOpus4   = ModelPrice(input: 15.00, output: 75.00)
    private static let claudeSonnet4 = ModelPrice(input:  3.00, output: 15.00)
    private static let claudeHaiku4  = ModelPrice(input:  1.00, output:  5.00)

    /// OpenAI — GPT-5 / 4.1 family (best public estimates).
    private static let gpt5      = ModelPrice(input: 1.25, output: 10.00)
    private static let gpt5Codex = ModelPrice(input: 1.25, output: 10.00)
    private static let gpt5Mini  = ModelPrice(input: 0.25, output:  2.00)
    private static let gpt41     = ModelPrice(input: 2.00, output:  8.00)

    /// Returns the retail rate for a model name, or nil if unknown.
    public static func price(for model: String) -> ModelPrice? {
        let m = canonical(model)
        if m.contains("haiku") { return claudeHaiku4 }
        if m.contains("sonnet") { return claudeSonnet4 }
        if m.contains("opus") { return claudeOpus4 }
        if m.contains("mini") { return gpt5Mini }
        if m.contains("codex") { return gpt5Codex }
        if m.hasPrefix("gpt-5") { return gpt5 }
        if m.hasPrefix("gpt-4") { return gpt41 }
        return nil
    }

    /// Estimated retail USD for a single record, using its model's rates.
    /// Returns 0 for records where we have no token data (e.g. chat-mode rows).
    public static func estimatedCost(for record: UsageRecord) -> Double {
        guard let p = price(for: record.model) else { return 0 }
        return p.cost(
            input: record.inputTokens,
            output: record.outputTokens,
            cacheRead: record.cacheReadTokens,
            cacheWrite: record.cacheWriteTokens
        )
    }

    /// What GitHub itself would bill, in USD, for the given accumulated
    /// premium-request units.
    public static func githubOverageUsd(premiumCost: Double) -> Double {
        premiumCost * usdPerPremiumRequest
    }

    private static func canonical(_ model: String) -> String {
        model.lowercased()
            .replacingOccurrences(of: "-internal", with: "")
            .replacingOccurrences(of: "-1m", with: "")
            .replacingOccurrences(of: "-xhigh", with: "")
            .replacingOccurrences(of: "-high", with: "")
            .replacingOccurrences(of: "--effort=", with: "-")
    }
}
