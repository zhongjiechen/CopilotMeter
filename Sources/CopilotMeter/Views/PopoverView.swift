import SwiftUI

struct PopoverView: View {
    @ObservedObject var refresher: UsageRefresher
    @State private var selectedWindow: TimeWindow = .today

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SourceLegend()
            tilesRow
            Divider()
            SelectedWindowDetail(
                window: selectedWindow,
                stats: refresher.snapshot.byWindow[selectedWindow] ?? .zero,
                blindChat: refresher.snapshot.blindChatByWindow[selectedWindow] ?? 0
            )
            Divider()
            ModelBreakdown(
                window: selectedWindow,
                byModel: refresher.snapshot.byWindowByModel[selectedWindow] ?? [:]
            )
            Divider()
            DailySparkline(data: refresher.snapshot.dailyRequests)
            footer
        }
        .padding(14)
        .frame(width: 500)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("CopilotMeter", systemImage: "chart.bar.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if refresher.isRefreshing {
                ProgressView().controlSize(.mini)
            } else if let ts = refresher.lastRefreshAt {
                Text("updated \(Formatters.relative(ts))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var tilesRow: some View {
        HStack(spacing: 8) {
            ForEach([TimeWindow.today, .week, .month], id: \.self) { w in
                WindowTile(
                    window: w,
                    stats: refresher.snapshot.byWindow[w] ?? .zero,
                    blindChat: refresher.snapshot.blindChatByWindow[w] ?? 0,
                    bySource: refresher.snapshot.byWindowBySource[w] ?? [:],
                    isSelected: w == selectedWindow,
                    onTap: { selectedWindow = w }
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = refresher.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err)
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.orange)
                    .help(err)
            } else {
                let all = refresher.snapshot.byWindow[.all] ?? .zero
                Text("All-time: \(Formatters.compactDouble(all.requests)) req · \(Formatters.compactInt(all.outputTokens)) out")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                refresher.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(refresher.isRefreshing)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
        }
    }
}
