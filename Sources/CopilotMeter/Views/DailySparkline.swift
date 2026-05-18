import SwiftUI

/// Simple bar-spark for the last 30 days of premium request counts.
struct DailySparkline: View {
    let data: [UsageAggregator.DailyPoint]   // chronological order, up to 30 points

    private var maxVal: Double {
        max(data.map { $0.requests }.max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LAST 30 DAYS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let last = data.last, last.requests > 0 {
                    Text("today: \(Formatters.compactDouble(last.requests))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                let count = max(data.count, 1)
                let barWidth = max(2, (geo.size.width - CGFloat(count - 1) * 2) / CGFloat(count))
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(data.enumerated()), id: \.offset) { idx, point in
                        let h = max(2, CGFloat(point.requests / maxVal) * geo.size.height)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(barColor(for: idx))
                            .frame(width: barWidth, height: h)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 36)
        }
    }

    private func barColor(for index: Int) -> Color {
        let isToday = index == data.count - 1
        if isToday { return .accentColor }
        return .accentColor.opacity(0.4)
    }
}
