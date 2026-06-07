import SwiftUI

/// Shows the selected window's cost using GitHub's AI Credit billing model.
struct CostEstimateRow: View {
    let stats: UsageStats

    @State private var showingFormulaInfo: Bool = false

    var body: some View {
        let aiuUsd = stats.aiCreditsUsd
        let retail = stats.estimatedRetailUsd
        let displayUsd = aiuUsd > 0 ? aiuUsd : retail
        let displayCredits = stats.aiCredits > 0 ? stats.aiCredits : retail * 100.0
        if displayUsd == 0 && displayCredits == 0 { EmptyView() } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                    Text("AI Credit cost")
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
                    if stats.aiCreditsAuthoritativeRows > 0 {
                        Text("AIU ✓")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.green.opacity(0.12))
                            )
                            .help("\(stats.aiCreditsAuthoritativeRows) row(s) carry authoritative `totalNanoAiu` from the Copilot CLI.")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Formatters.compactCredits(displayCredits)) AI Credits")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text("≈ \(Formatters.compactUSD(displayUsd))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                )
                .help("""
                    GitHub's AI Credit billing model. When the Copilot CLI emits \
                    `session.shutdown.modelMetrics.<model>.totalNanoAiu` we read it directly; otherwise \
                    we estimate from token rates. 1 AI Credit = $0.01 USD.
                    """)
            }
        }
    }
}

/// Detailed explanation of AI Credit billing, surfaced via the ⓘ button.
/// Kept terse — power users can read the source for the full story.
private struct CostFormulaPopover: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header

                Text("**Starting 2026-06-01** GitHub Copilot usage is billed in **GitHub AI Credits**. 1 AI Credit = $0.01 USD. Code completions and Next Edit suggestions remain **free**.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                section(
                    title: "AI Credits",
                    icon: "shippingbox.fill",
                    accent: .blue
                ) {
                    Text("**Authoritative path.** When the Copilot CLI writes `session.shutdown.modelMetrics.<model>.totalNanoAiu` we read it directly: AIU = totalNanoAiu ÷ 10⁹, USD = AIU × $0.01.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("**Fallback path** (older CLI sessions / VS Code Chat without AIU in the rollup):")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    formula("fresh = max(0, input − cache_read − cache_write)")
                    formula("cost  = fresh        × in_rate")
                    formula("      + cache_read   × cache_read_rate")
                    formula("      + cache_write  × cache_write_rate   (Anthropic)")
                    formula("      + output       × out_rate")
                    formula("AIU = cost × 100        (since 1 AIU = $0.01)")

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
                    Text("Some VS Code Chat sessions don't write token counts or `totalNanoAiu` to disk — the extension marks `assistant.usage` events `ephemeral` and filters them out of the transcript. Those sessions are omitted from AI Credit billing stats because no billable usage data is available locally.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .frame(width: 380, height: 430)
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
