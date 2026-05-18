import SwiftUI

/// Compact per-remote summary chip strip. Hidden entirely when no remote
/// activity is present in the selected window.
struct RemotesStrip: View {
    let window: TimeWindow
    let byRemote: [String?: UsageStats]

    /// Non-nil keys, sorted by request count desc.
    private var remotes: [(String, UsageStats)] {
        byRemote
            .compactMap { (key, value) -> (String, UsageStats)? in
                guard let name = key, value.requests > 0 else { return nil }
                return (name, value)
            }
            .sorted { $0.1.requests > $1.1.requests }
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
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.system(size: 9))
                                .foregroundStyle(.indigo)
                            Text("@\(name)")
                                .font(.system(size: 11, weight: .medium))
                            Text("\(Formatters.compactDouble(stats.requests))")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.indigo.opacity(0.12))
                        )
                        .help("\(name): \(Int(stats.requests.rounded())) requests · \(Formatters.compactInt(stats.outputTokens)) out · \(Formatters.compactInt(stats.inputTokens)) in")
                    }
                    Spacer()
                }
            }
        } else {
            EmptyView()
        }
    }
}
