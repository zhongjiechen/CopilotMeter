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
                            Legacy request-based billing — only applies to Pro/Pro+ annual \
                            subscribers who stayed on it after 2026-06-01. Computed from \
                            the recorded `requests.cost` × $\(String(format: "%.2f", PricingCatalog.usdPerPremiumRequest)) per premium-request unit. \
                            For Enterprise / usage-based-billing users it reads $0.00 — see the AI Credits column instead.
                            """
                    )
                    costCell(
                        label: "AI Credits",
                        value: retail,
                        help: """
                            GitHub's official 2026 usage-based bill. Each model's input / output / cache_read \
                            tokens are charged at the per-million rate published at \
                            docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing. \
                            1 AI Credit = $0.01 USD, so the USD figure shown here is exactly the AI-Credits cost.
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

                Text("**Starting 2026-06-01** GitHub moved Copilot from flat \"premium request\" billing to **usage-based billing in GitHub AI Credits**. 1 AI Credit = $0.01 USD. Code completions and Next Edit suggestions remain **free**.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                section(
                    title: "GitHub bill  (legacy / annual request-based)",
                    icon: "creditcard.fill",
                    accent: .green
                ) {
                    formula("Σ premium_cost × $0.04")
                    Text("Pro / Pro+ **annual** subscribers can stay on request-based billing. `premium_cost` is GitHub's per-request unit count recorded in each session's `modelMetrics.<model>.requests.cost`; `$0.04` is the per-unit overage rate. Constant: `PricingCatalog.usdPerPremiumRequest`.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Reads $0.00 for monthly / Enterprise users on usage-based billing — see the AI Credits column instead.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }

                Divider()

                section(
                    title: "AI Credits  (default after 2026-06-01)",
                    icon: "shippingbox.fill",
                    accent: .blue
                ) {
                    formula("fresh = max(0, input − cache_read − cache_write)")
                    formula("cost  = fresh        × in_rate")
                    formula("      + cache_read   × cache_read_rate")
                    formula("      + cache_write  × cache_write_rate   (Anthropic)")
                    formula("      + output       × out_rate")

                    Text("Per-million-token rates from GitHub Docs (2026-05):")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    rateTable
                    Text("Model name matching strips `-internal`, `-1m`, `-xhigh`, `-high`, `--effort=` (`PricingCatalog.canonical`). E.g. `claude-opus-4.7-1m-internal` falls through to the Opus row.")
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
        .frame(width: 380, height: 520)
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
            rateRow("Claude Opus 4.5/4.6/4.7", "$5",     "$25")
            rateRow("Claude Sonnet 4.x",       "$3",     "$15")
            rateRow("Claude Haiku 4.5",        "$1",     "$5")
            rateRow("GPT-5.5",                 "$5",     "$30")
            rateRow("GPT-5.4",                 "$2.50",  "$15")
            rateRow("GPT-5.4 mini",            "$0.75",  "$4.50")
            rateRow("GPT-5.4 nano",            "$0.20",  "$1.25")
            rateRow("GPT-5.2 / 5.3-Codex",     "$1.75",  "$14")
            rateRow("GPT-5 mini / Raptor mini","$0.25",  "$2")
            rateRow("GPT-4.1",                 "$2",     "$8")
            rateRow("Gemini 3.1 Pro",          "$2",     "$12")
            rateRow("Gemini 2.5 Pro / Goldeneye","$1.25","$10")
            rateRow("Gemini 3 Flash",          "$0.50",  "$3")
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
