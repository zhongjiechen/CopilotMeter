import SwiftUI

/// Shows the estimated USD cost of the selected window, both at GitHub's
/// per-premium-request overage rate and at the underlying provider's retail
/// token rate. Useful as a "what-am-I-getting" indicator for enterprise users
/// whose seats include unlimited usage and therefore see no dollar amount in
/// the GitHub dashboard.
struct CostEstimateRow: View {
    let stats: UsageStats

    var body: some View {
        let gh = stats.githubOverageUsd
        let retail = stats.estimatedRetailUsd
        if gh == 0 && retail == 0 { EmptyView() } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("Estimated cost")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    costCell(
                        label: "GitHub bill",
                        value: gh,
                        help: """
                            What GitHub would bill at $\(String(format: "%.2f", PricingCatalog.usdPerPremiumRequest)) per premium-request unit. \
                            Computed from the recorded 'requests.cost' field. For enterprise plans where the cost is recorded as 0, this row reads $0.00.
                            """
                    )
                    costCell(
                        label: "Retail tokens",
                        value: retail,
                        help: """
                            Best-effort retail cost if you paid the underlying provider directly per token. \
                            Uses public 2025 rates: Claude Opus $15/$75 per M in/out, Sonnet $3/$15, Haiku $1/$5, \
                            GPT-5 $1.25/$10, GPT-5 mini $0.25/$2. Cache reads at 10% of input. \
                            Pricing constants live in Sources/CopilotMeter/Pricing/PricingCatalog.swift.
                            """
                    )
                }
            }
        }
    }

    private func costCell(label: String, value: Double, help: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(formatUSD(value))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .help(help)
    }

    private func formatUSD(_ v: Double) -> String {
        if v >= 1_000 {
            return String(format: "$%.0f", v)
        } else if v >= 10 {
            return String(format: "$%.2f", v)
        } else if v > 0 {
            return String(format: "$%.3f", v)
        } else {
            return "$0.00"
        }
    }
}
