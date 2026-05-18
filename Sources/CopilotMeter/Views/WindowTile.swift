import SwiftUI

/// Compact tile: big request count, source split as a stacked bar.
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

                Text(Formatters.compactDouble(stats.requests))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 4) {
                    Text("requests")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if blindChat > 0 {
                        Text("+\(blindChat)")
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

/// Stacked horizontal bar showing the relative size of each source.
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
                        .help("\(seg.source.shortLabel): \(Formatters.compactDouble(seg.value)) req")
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
            let v = (bySource[src]?.requests ?? 0)
            if v > 0 { out.append(Segment(source: src, value: v)) }
        }
        return out
    }
}
