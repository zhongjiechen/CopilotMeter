import SwiftUI

/// Compact per-remote summary chip strip. Hidden entirely when no remote
/// activity is present in the selected window.
///
/// Display rule: each chip shows AI Credits only. Sources without token/AIU
/// data are intentionally omitted from billing stats.
///
/// Hover tooltip on each chip lists the per-source breakdown
/// (Cloud Agent / CLI / VS Code Agent / VS Code Chat) so users
/// can see which sources contributed — e.g. resumed `copilot --resume`
/// sessions against an agent worktree show up under Cloud Agent, which
/// can be confusing without an explicit decomposition.
struct RemotesStrip: View {
    let window: TimeWindow
    let byRemote: [String?: UsageStats]
    /// Per-(host, source) joint aggregate; used by the chip tooltip.
    /// Same key convention as `byRemote` (`nil` = local).
    let byRemoteSource: [String?: [UsageRecord.Source: UsageStats]]

    /// Non-nil keys, sorted by AI Credits desc.
    private var remotes: [(String, UsageStats)] {
        byRemote
            .compactMap { (key, value) -> (String, UsageStats)? in
                guard let name = key, value.aiCredits > 0 else { return nil }
                return (name, value)
            }
            .sorted { $0.1.aiCredits > $1.1.aiCredits }
    }

    /// Whether any non-local activity exists at all (across all windows of the snapshot).
    private var hasAny: Bool { !remotes.isEmpty }

    var body: some View {
        if hasAny {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(window.displayName.uppercased()) — REMOTE HOSTS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(remotes, id: \.0) { name, stats in
                        chip(name: name, stats: stats)
                    }
                    Spacer()
                }
                Text("Tip: hover a chip to see the per-source AI Credit breakdown. Sessions you resume with `copilot --resume` against an agent worktree show up under **Cloud Agent**, not CLI — that's the original GitHub Coding Agent session you're continuing.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func chip(name: String, stats: UsageStats) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "network")
                .font(.system(size: 9))
                .foregroundStyle(.indigo)
            Text("@\(name)")
                .font(.system(size: 11, weight: .medium))
            Text(Formatters.compactCredits(stats.aiCredits))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.indigo.opacity(0.12))
        )
        .help(tooltip(name: name, stats: stats))
    }

    private func tooltip(name: String, stats: UsageStats) -> String {
        // Header line summarizing the host total.
        let header = """
            \(name): \(Formatters.compactCredits(stats.aiCredits)) AI Credits \
            ≈ \(Formatters.compactUSD(stats.aiCreditsUsd)) · \
            \(Formatters.compactInt(stats.outputTokens)) out · \
            \(Formatters.compactInt(stats.inputTokens)) in
            """

        // Per-source breakdown lines, sorted by credits desc.
        // Keeps the four canonical source labels stable so users can
        // mentally pattern-match across hosts.
        guard let bySource = byRemoteSource[name], !bySource.isEmpty else {
            return header
        }
        let sorted = bySource
            .map { (source, s) -> (UsageRecord.Source, UsageStats) in (source, s) }
            .filter { $0.1.aiCredits > 0 }
            .sorted { $0.1.aiCredits > $1.1.aiCredits }
        let lines = sorted.map { (source, s) -> String in
            let label = source.shortLabel
            return "  • \(label): \(Formatters.compactCredits(s.aiCredits)) cr"
        }
        guard !lines.isEmpty else { return header }
        return header + "\n\nBy source:\n" + lines.joined(separator: "\n")
    }
}
