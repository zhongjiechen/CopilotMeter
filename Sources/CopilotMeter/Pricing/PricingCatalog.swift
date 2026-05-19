import Foundation

/// Per-million-token rates for a single model, in GitHub AI Credits (1 credit
/// = $0.01 USD, so the values double as retail-USD-equivalent numbers).
public struct ModelPrice: Sendable, Equatable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheWritePerMillion: Double

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.inputPerMillion = input
        self.outputPerMillion = output
        // Anthropic publishes cache-read at 10% of input and cache-write at
        // 125% of input. OpenAI's cache-read is 10% across the board.
        // Google publishes cache-read at 10%. When a model's rate isn't
        // explicitly known we fall back to those defaults.
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
    public func cost(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        let freshInput = max(0, input - cacheRead - cacheWrite)
        let i = Double(freshInput) * inputPerMillion       / 1_000_000.0
        let r = Double(cacheRead)  * cacheReadPerMillion   / 1_000_000.0
        let w = Double(cacheWrite) * cacheWritePerMillion  / 1_000_000.0
        let o = Double(output)     * outputPerMillion      / 1_000_000.0
        return i + r + w + o
    }
}

/// Maps each model name Copilot logs (`claude-opus-4.7-1m-internal`, `gpt-5.5`,
/// `claude-sonnet-4.6`, …) to its **official GitHub AI Credit** rate from
/// <https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing>.
///
/// **Billing landscape after 2026-06-01**: Copilot moved from a flat
/// "premium request" subscription model to **usage-based billing in GitHub
/// AI Credits**. 1 AI credit = $0.01 USD, so the per-million-token prices
/// below are simultaneously:
///   - exact GitHub bill numbers (for users on usage-based billing)
///   - retail-USD equivalents (since 1 credit = $0.01)
///
/// Code completions and Next Edit suggestions remain **free** and are not
/// billed in AI credits.
///
/// Legacy Pro / Pro+ annual subscribers who opted to remain on
/// request-based billing still pay `$0.04 per premium-request unit`; that
/// constant is kept for backward compatibility.
///
/// Pricing constants reflect the published table as of 2026-05. Keep this
/// file in sync with the GitHub docs link above when rates change.
public enum PricingCatalog {

    /// 2026 GitHub Copilot moved to AI-Credit-based usage billing on this date.
    public static let billingTransitionDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 1
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }()

    /// Legacy: USD per "premium request unit" for annual-plan subscribers who
    /// stayed on request-based billing. Was the GitHub overage rate across
    /// Pro / Pro+ / Business / Enterprise.
    public static let usdPerPremiumRequest: Double = 0.04

    // MARK: - OpenAI

    private static let gpt41        = ModelPrice(input: 2.00,  output: 8.00,   cacheRead: 0.50)
    private static let gpt5Mini     = ModelPrice(input: 0.25,  output: 2.00,   cacheRead: 0.025)
    private static let gpt5_2       = ModelPrice(input: 1.75,  output: 14.00,  cacheRead: 0.175)
    private static let gpt5_2Codex  = ModelPrice(input: 1.75,  output: 14.00,  cacheRead: 0.175)
    private static let gpt5_3Codex  = ModelPrice(input: 1.75,  output: 14.00,  cacheRead: 0.175)
    private static let gpt5_4       = ModelPrice(input: 2.50,  output: 15.00,  cacheRead: 0.25)
    private static let gpt5_4Mini   = ModelPrice(input: 0.75,  output: 4.50,   cacheRead: 0.075)
    private static let gpt5_4Nano   = ModelPrice(input: 0.20,  output: 1.25,   cacheRead: 0.02)
    private static let gpt5_5       = ModelPrice(input: 5.00,  output: 30.00,  cacheRead: 0.50)

    // MARK: - Anthropic
    // Cache-write is explicit per the docs.

    private static let claudeHaiku4_5  = ModelPrice(input: 1.00, output: 5.00,  cacheRead: 0.10, cacheWrite: 1.25)
    private static let claudeSonnet4   = ModelPrice(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75)
    private static let claudeOpus      = ModelPrice(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25)

    // MARK: - Google

    private static let gemini25Pro     = ModelPrice(input: 1.25, output: 10.00, cacheRead: 0.125)
    private static let gemini3Flash    = ModelPrice(input: 0.50, output: 3.00,  cacheRead: 0.05)
    private static let gemini31Pro     = ModelPrice(input: 2.00, output: 12.00, cacheRead: 0.20)

    // MARK: - Fine-tuned (GitHub)

    private static let raptorMini      = ModelPrice(input: 0.25, output: 2.00,  cacheRead: 0.025) // = GPT-5 mini pricing
    private static let goldeneye       = ModelPrice(input: 1.25, output: 10.00, cacheRead: 0.125) // = GPT-5.1-Codex pricing

    /// Returns the rate for a model name, or nil if unknown.
    public static func price(for model: String) -> ModelPrice? {
        let m = canonical(model)

        // --- Anthropic ---
        if m.contains("haiku") { return claudeHaiku4_5 }
        if m.contains("opus")  { return claudeOpus }
        if m.contains("sonnet") { return claudeSonnet4 }

        // --- Google ---
        if m.contains("gemini-3-flash") || m.contains("gemini3-flash") || m.contains("gemini-3.flash") { return gemini3Flash }
        if m.contains("gemini-3.1") || m.contains("gemini-3-1") { return gemini31Pro }
        if m.contains("gemini") { return gemini25Pro }

        // --- GitHub fine-tuned ---
        if m.contains("raptor") { return raptorMini }
        if m.contains("goldeneye") { return goldeneye }

        // --- OpenAI (most specific first) ---
        if m.hasPrefix("gpt-5.5") || m.hasPrefix("gpt-55") { return gpt5_5 }
        if m.hasPrefix("gpt-5.4-mini") { return gpt5_4Mini }
        if m.hasPrefix("gpt-5.4-nano") { return gpt5_4Nano }
        if m.hasPrefix("gpt-5.4") { return gpt5_4 }
        if m.hasPrefix("gpt-5.3-codex") { return gpt5_3Codex }
        if m.hasPrefix("gpt-5.3") { return gpt5_3Codex }
        if m.hasPrefix("gpt-5.2-codex") { return gpt5_2Codex }
        if m.hasPrefix("gpt-5.2") { return gpt5_2 }
        if m.hasPrefix("gpt-5-codex") || (m.contains("gpt-5") && m.contains("codex")) { return goldeneye }
        if m.hasPrefix("gpt-5-mini") || (m.contains("gpt-5") && m.contains("mini")) { return gpt5Mini }
        if m.hasPrefix("gpt-5") { return gpt5_2 }   // unspecified GPT-5 → 5.2 baseline
        if m.hasPrefix("gpt-4")  { return gpt41 }

        return nil
    }

    /// Estimated USD cost for a single record at its model's GitHub AI Credit rates.
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
    /// premium-request units. Legacy: only applies to annual-plan
    /// subscribers who stayed on request-based billing after 2026-06-01.
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
