import SwiftUI

/// Collapsible panel listing the host aliases parsed from `~/.ssh/config`
/// with a checkbox for each. Checking a host adds it to remotes.json and
/// triggers a sync; unchecking removes it and wipes its cached records.
struct HostsPanel: View {
    @ObservedObject var refresher: UsageRefresher
    @State private var expanded: Bool = false

    private var enabledCount: Int { refresher.enabledRemotes.count }
    private var discoveredCount: Int { refresher.discoveredHosts.count }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Heads up: the FIRST sync of a remote can take 5–10 minutes (it has to pull the whole ~/.copilot/session-state). After that, each refresh is incremental and finishes in seconds. Remote refresh runs automatically once an hour; tap ↻ in the footer to force one now.")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                if refresher.discoveredHosts.isEmpty {
                    Text("No hosts found in ~/.ssh/config")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(refresher.discoveredHosts) { host in
                                HostRow(refresher: refresher, host: host)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                Text("Each enabled host's `~/.copilot/session-state` and VS Code Copilot Chat DB are pulled via `rsync` over SSH. Data is cached at `~/Library/Application Support/CopilotMeter/remotes/`.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(.indigo)
                Text("Remote hosts")
                    .font(.caption.weight(.semibold))
                if enabledCount > 0 {
                    Text("\(enabledCount) enabled · \(discoveredCount) discovered")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(discoveredCount) discovered · auto-sync hourly")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if refresher.isRefreshing && enabledCount > 0 {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .onAppear {
            refresher.reloadDiscoveredHosts()
        }
    }
}

private struct HostRow: View {
    @ObservedObject var refresher: UsageRefresher
    let host: SSHConfigParser.DiscoveredHost

    @State private var pendingToggle: Bool = false

    private var isEnabled: Bool {
        refresher.isEnabled(host.name)
    }
    private var status: RemoteSyncStatus? {
        refresher.remoteStatus[host.name]
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    pendingToggle = newValue
                    refresher.setRemoteEnabled(newValue, host: host)
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(host.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 4)
            statusBadge
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .help(host.identityFile.map { "Identity: \($0)" } ?? host.name)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !isEnabled {
            EmptyView()
        } else if let s = status {
            switch s.phase {
            case .syncing:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("syncing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .success:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    if let ts = s.lastSyncedAt {
                        Text(Formatters.relative(ts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(s.lastError ?? "failed")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(s.lastError ?? "Sync failed")
            case .idle:
                Text("queued")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("queued")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
