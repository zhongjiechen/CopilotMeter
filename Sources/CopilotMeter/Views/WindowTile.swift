import SwiftUI

/// Compact tile: big AI-Credits number, USD subtitle, source split as a stacked bar.
/// All token detail is deferred to the SelectedWindowDetail panel below the tiles,
/// to keep tiles narrow and avoid clipping.
struct WindowTile: View {
    let window: TimeWindow
    let stats: UsageStats
    let blindChat: Int
    let bySource: [UsageRecord.Source: UsageStats]
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(window.displayName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(Formatters.compactCredits(stats.aiCredits))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 4) {
                    Text("AI Credits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(Formatters.compactUSD(stats.aiCreditsUsd))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                        .help("USD equivalent at the post-2026-06-01 rate of $0.01 per AI Credit")
                }

                HStack(spacing: 4) {
                    Text("\(Int(stats.requests.rounded())) req")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    if blindChat > 0 {
                        Text("+\(blindChat) chat")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(UsageRecord.Source.vscodeChat.color)
                            .help("\(blindChat) VS Code Chat interactions with no token data")
                    }
                }

                SourceSplitBar(bySource: bySource, blindChat: blindChat)
                    .frame(height: 6)
                    .padding(.top, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Stacked horizontal bar showing the relative AI-Credit share of each source.
private struct SourceSplitBar: View {
    let bySource: [UsageRecord.Source: UsageStats]
    let blindChat: Int

    var body: some View {
        GeometryReader { geo in
            let segments = buildSegments()
            let total = max(segments.reduce(0) { $0 + $1.value }, 1)
            HStack(spacing: 1) {
                ForEach(segments) { seg in
                    let w = max(2, CGFloat(seg.value / total) * (geo.size.width - CGFloat(max(segments.count - 1, 0))))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(seg.source.color)
                        .frame(width: w)
                        .help("\(seg.source.shortLabel): \(Formatters.compactCredits(seg.value)) credits")
                }
                if segments.isEmpty {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                }
            }
        }
    }

    private struct Segment: Identifiable {
        let source: UsageRecord.Source
        let value: Double
        var id: String { source.rawValue }
    }

    private func buildSegments() -> [Segment] {
        var out: [Segment] = []
        for src in [UsageRecord.Source.copilotCLI, .vscodeAgent, .vscodeChat] {
            // Width by credits when we have token data; fall back to request
            // count for chat sessions (no token data → no credits) so the bar
            // still reflects activity.
            let credits = (bySource[src]?.aiCredits ?? 0)
            let reqs = (bySource[src]?.requests ?? 0)
            let v = credits > 0 ? credits : reqs
            if v > 0 { out.append(Segment(source: src, value: v)) }
        }
        return out
    }
}
