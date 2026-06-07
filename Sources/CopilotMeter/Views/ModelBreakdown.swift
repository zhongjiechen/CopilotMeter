import SwiftUI

/// Top-models list for the currently selected time window.
struct ModelBreakdown: View {
    let window: TimeWindow
    let byModel: [String: UsageStats]

    private var topModels: [(String, UsageStats)] {
        byModel
            .filter { $0.value.aiCredits > 0 || $0.value.outputTokens > 0 }
            .sorted {
                if $0.value.aiCredits != $1.value.aiCredits { return $0.value.aiCredits > $1.value.aiCredits }
                return $0.value.outputTokens > $1.value.outputTokens
            }
            .prefix(6)
            .map { ($0.key, $0.value) }
    }

    private var maxCredits: Double {
        max(topModels.map(\.1.aiCredits).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TOP MODELS — \(window.displayName.uppercased())")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !byModel.isEmpty {
                    Text("\(topModels.count) of \(byModel.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if topModels.isEmpty {
                Text("No activity in this window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(topModels, id: \.0) { name, stats in
                    ModelRow(name: name, stats: stats, fraction: stats.aiCredits / maxCredits)
                }
            }
        }
    }
}

private struct ModelRow: View {
    let name: String
    let stats: UsageStats
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
                Spacer(minLength: 8)
                Text("\(Formatters.compactCredits(stats.aiCredits)) cr")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .help("AI Credits ≈ \(Formatters.compactUSD(stats.aiCreditsUsd))")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [.accentColor.opacity(0.9), .accentColor.opacity(0.6)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 4)

            // Per-model details on a separate line. WrapHStack so they don't truncate.
            FlowingMetrics(stats: stats)
        }
        .padding(.vertical, 1)
    }

    private var displayName: String {
        // Use the full model name; the .help() modifier provides a tooltip.
        // Only strip the very long "-internal" suffix for visual cleanliness.
        name.replacingOccurrences(of: "-internal", with: "")
    }
}

/// Renders model-detail metrics with explicit labels; uses .lineLimit(2) and
/// fixedSize on the inner texts to ensure they wrap rather than truncate.
private struct FlowingMetrics: View {
    let stats: UsageStats

    var body: some View {
        // Combine into a single small string so SwiftUI handles wrapping naturally.
        let parts = composedParts()
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func composedParts() -> [String] {
        var parts: [String] = []
        if stats.outputTokens > 0 {
            parts.append("\(Formatters.compactInt(stats.outputTokens)) out")
        }
        if stats.inputTokens > 0 {
            parts.append("\(Formatters.compactInt(stats.inputTokens)) in")
        }
        if let rate = stats.cacheHitRate, stats.cacheReadTokens > 0 {
            parts.append(String(format: "%.0f%% cached", rate * 100))
        }
        if stats.aiCreditsUsd > 0 {
            parts.append("≈\(Formatters.compactUSD(stats.aiCreditsUsd))")
        }
        return parts
    }
}
