import SwiftUI

struct PopoverView: View {
    @ObservedObject var refresher: UsageRefresher
    @ObservedObject var updates: UpdateChecker
    @State private var selectedWindow: TimeWindow = .today

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if updates.hasUpdate, let r = updates.latestRelease {
                UpdateBanner(release: r, currentVersion: updates.currentVersion)
            }
            SourceLegend()
            tilesRow
            HostsPanel(refresher: refresher)
            Divider()
            SelectedWindowDetail(
                window: selectedWindow,
                stats: refresher.snapshot.byWindow[selectedWindow] ?? .zero,
                blindChat: refresher.snapshot.blindChatByWindow[selectedWindow] ?? 0
            )
            RemotesStrip(
                window: selectedWindow,
                byRemote: refresher.snapshot.byWindowByRemote[selectedWindow] ?? [:]
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
            Text("v\(updates.currentVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Current installed version. Check the orange banner above when a new release is available — or visit the Releases page.")
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
                Text("All-time: \(Formatters.compactCredits(all.aiCredits)) cr · \(Formatters.compactUSD(all.aiCreditsUsd)) · \(Formatters.compactDouble(all.requests)) req")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("All-time AI Credits / USD / request count across local + remote sources.")
            }
            Spacer()
            Button {
                refresher.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now (also re-runs remote sync)")
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
