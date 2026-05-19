import SwiftUI

/// Shows the estimated USD cost of the selected window, both at GitHub's
/// per-premium-request overage rate and at the underlying provider's retail
/// token rate. Useful as a "what-am-I-getting" indicator for enterprise users
/// whose seats include unlimited usage and therefore see no dollar amount in
/// the GitHub dashboard.
struct CostEstimateRow: View {
    let stats: UsageStats

    @State private var showingFormulaInfo: Bool = false

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
                    Button {
                        showingFormulaInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("How are these numbers computed?")
                    .popover(isPresented: $showingFormulaInfo, arrowEdge: .top) {
                        CostFormulaPopover()
                    }
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

/// Detailed explanation of the two cost columns, surfaced via the ⓘ button.
/// Kept terse — power users can read the source for the full story.
private struct CostFormulaPopover: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header

                section(
                    title: "GitHub bill",
                    icon: "creditcard.fill",
                    accent: .green
                ) {
                    formula("Σ premium_cost × $0.04")
                    Text("`premium_cost` is the per-request unit count GitHub itself records in each session's `modelMetrics.<model>.requests.cost`. `$0.04` is the 2025 Pro/Pro+/Business/Enterprise overage rate. Constant: `PricingCatalog.usdPerPremiumRequest`.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Enterprise users still get a non-zero number here even though GitHub bills them $0 — it's what the same usage *would* cost on a metered plan.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }

                Divider()

                section(
                    title: "Retail tokens",
                    icon: "shippingbox.fill",
                    accent: .blue
                ) {
                    formula("fresh = max(0, input − cache_read − cache_write)")
                    formula("cost = fresh × in_rate")
                    formula("     + cache_read × 0.10 × in_rate")
                    formula("     + cache_write × 1.25 × in_rate")
                    formula("     + output × out_rate")

                    Text("Per-million-token rates (2025 public list prices):")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    rateTable
                    Text("Model name matching strips suffixes like `-internal`, `-1m`, `-xhigh` (`PricingCatalog.canonical`), so `claude-opus-4.7-1m-internal` falls through to the Opus row.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }

                Divider()

                section(
                    title: "Sources without token data",
                    icon: "questionmark.diamond",
                    accent: .orange
                ) {
                    Text("**VS Code Chat / Agent** sessions don't write token counts to disk — the extension marks `assistant.usage` events `ephemeral` and filters them out of the transcript. These records contribute **$0** to both columns; only their request counts are visible.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .frame(width: 360, height: 480)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "function")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Text("How costs are computed")
                .font(.headline)
        }
    }

    private func section<Content: View>(
        title: String, icon: String, accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            content()
        }
    }

    private func formula(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.10))
            )
    }

    private var rateTable: some View {
        VStack(alignment: .leading, spacing: 2) {
            rateRow("Claude Opus", "$15", "$75")
            rateRow("Claude Sonnet", "$3", "$15")
            rateRow("Claude Haiku", "$1", "$5")
            rateRow("GPT-5 / GPT-5 Codex", "$1.25", "$10")
            rateRow("GPT-5 mini", "$0.25", "$2")
            rateRow("GPT-4.1", "$2", "$8")
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func rateRow(_ name: String, _ inRate: String, _ outRate: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text("in \(inRate)  out \(outRate)")
                .foregroundStyle(.primary)
        }
    }
}
