import Foundation
import Combine

/// Per-host sync status surfaced to the UI.
public struct RemoteSyncStatus: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case idle, syncing, success, failed
    }
    public let host: String
    public let phase: Phase
    public let lastSyncedAt: Date?
    public let lastError: String?
}

/// Top-level service: scans data sources, updates the cache, and publishes
/// an aggregated `Snapshot` for the UI to consume.
///
/// IO work runs in a detached Task to keep the UI responsive; only the
/// resulting Snapshot is hopped back to the main actor for publishing.
@MainActor
public final class UsageRefresher: ObservableObject {
    @Published public private(set) var snapshot: UsageAggregator.Snapshot = .empty
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastRefreshAt: Date?
    /// Per-host status for enabled remotes (key = host nickname).
    @Published public private(set) var remoteStatus: [String: RemoteSyncStatus] = [:]
    /// User-discoverable hosts read from ~/.ssh/config (refreshed at startup
    /// and whenever the popover opens via `reloadDiscoveredHosts()`).
    @Published public private(set) var discoveredHosts: [SSHConfigParser.DiscoveredHost] = []
    /// Currently enabled remotes, persisted in remotes.json. Empty by default.
    @Published public private(set) var enabledRemotes: [RemoteHost] = []

    private let sessionStateDir: URL
    private let cachePath: String

    private var timer: Timer?
    private var inFlight: Task<Void, Never>?

    public init(sessionStateDir: URL? = nil, cachePath: String = CacheStore.defaultPath) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionStateDir = sessionStateDir ?? home.appendingPathComponent(".copilot/session-state")
        self.cachePath = cachePath
        reloadDiscoveredHosts()
        reloadEnabledRemotes()
    }

    /// Auto-refresh interval for local data (cheap, file-based).
    public nonisolated static let localRefreshInterval: TimeInterval = 60

    /// Auto-refresh interval for remote (SSH/rsync) sync. Remote initial sync
    /// can take several minutes on large session-state dirs, so we keep this
    /// generous. Subsequent rsync runs are incremental and finish in seconds.
    public nonisolated static let remoteRefreshInterval: TimeInterval = 3600   // 1 hour

    public func startAutoRefresh(every seconds: TimeInterval = UsageRefresher.localRefreshInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // First refresh: local sources only (instant), remote will follow when
        // its slower timer ticks.
        refresh()
        // Kick off the first remote sync immediately after launch so the user
        // gets data into the cache as soon as the long initial rsync completes.
        if !enabledRemotes.isEmpty {
            scheduleRemoteRefresh(after: 1)
        }
    }

    /// Independent slow-cadence timer for remote refresh.
    private var remoteTimer: Timer?

    private func scheduleRemoteRefresh(after delay: TimeInterval) {
        remoteTimer?.invalidate()
        remoteTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(includeRemotes: true)
                self.scheduleRemoteRefresh(after: UsageRefresher.remoteRefreshInterval)
            }
        }
    }

    public func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        remoteTimer?.invalidate()
        remoteTimer = nil
    }

    public func reloadDiscoveredHosts() {
        discoveredHosts = SSHConfigParser.loadHosts()
    }

    public func reloadEnabledRemotes() {
        let (cfg, err) = RemotesConfig.load()
        enabledRemotes = cfg.remotes
        if let err { lastError = err }
    }

    /// Adds or removes a host from the enabled list and persists to disk.
    /// Enabling a host immediately triggers a remote refresh (which may be slow).
    public func setRemoteEnabled(_ enabled: Bool, host: SSHConfigParser.DiscoveredHost) {
        var current = enabledRemotes
        if enabled {
            guard !current.contains(where: { $0.name == host.name }) else { return }
            current.append(RemoteHost(name: host.name, sshHost: host.name, identityFile: host.identityFile))
        } else {
            current.removeAll { $0.name == host.name }
            try? clearRecordsForRemote(host.name)
            try? FileManager.default.removeItem(at:
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/CopilotMeter/remotes")
                    .appendingPathComponent(host.name))
            remoteStatus.removeValue(forKey: host.name)
        }
        let cfg = RemotesConfig(remotes: current)
        do {
            try cfg.save()
            enabledRemotes = current
            if enabled {
                // Mark immediately so the row turns into a spinner before the
                // refresh actually fires.
                remoteStatus[host.name] = RemoteSyncStatus(
                    host: host.name, phase: .syncing, lastSyncedAt: nil, lastError: nil
                )
                refresh(includeRemotes: true)
            } else {
                refresh(includeRemotes: false)
            }
        } catch {
            lastError = "Couldn't save remotes.json: \(error)"
        }
    }

    /// True if a remote is in the persisted config.
    public func isEnabled(_ name: String) -> Bool {
        enabledRemotes.contains(where: { $0.name == name })
    }

    private func clearRecordsForRemote(_ name: String) throws {
        let db = try SQLite(path: cachePath, readOnly: false)
        try db.execute("DELETE FROM records WHERE remote_name = ?", bindings: [name])
        try db.execute("DELETE FROM file_state WHERE file_path LIKE ?",
                       bindings: ["%/remotes/\(name)/%"])
    }

    public func refresh(includeRemotes: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let dir = self.sessionStateDir
        let cachePath = self.cachePath
        // Only pass remotes to the worker when this is a "full" refresh.
        // The fast 60-second timer calls refresh() with no args → local only.
        let remotes: [RemoteHost] = includeRemotes ? self.enabledRemotes : []

        if includeRemotes {
            for r in remotes {
                let previous = remoteStatus[r.name]
                remoteStatus[r.name] = RemoteSyncStatus(
                    host: r.name,
                    phase: .syncing,
                    lastSyncedAt: previous?.lastSyncedAt,
                    lastError: nil
                )
            }
        }

        inFlight?.cancel()
        inFlight = Task.detached(priority: .utility) {
            let result = RefreshWorker.run(cachePath: cachePath, sessionStateDir: dir, remotes: remotes)
            await MainActor.run {
                self.snapshot = result.snapshot
                self.lastError = result.errorMessage
                self.lastRefreshAt = Date()
                for status in result.remoteStatuses {
                    self.remoteStatus[status.host] = status
                }
                self.isRefreshing = false
            }
        }
    }

    /// Manual user-triggered refresh (button in popover): always include remotes.
    public func refreshNow() {
        refresh(includeRemotes: true)
        // Reset the slow timer so the next automatic remote refresh is still
        // an hour away.
        scheduleRemoteRefresh(after: UsageRefresher.remoteRefreshInterval)
    }
}

/// Detached worker that does all blocking IO. All values used here are Sendable
/// (Strings, URLs, and types we control). The worker does not reach back into
/// the @MainActor refresher.
enum RefreshWorker {
    struct Result: Sendable {
        let snapshot: UsageAggregator.Snapshot
        let errorMessage: String?
        let remoteStatuses: [RemoteSyncStatus]
    }

    static func run(cachePath: String, sessionStateDir: URL, remotes: [RemoteHost] = []) -> Result {
        // Each ingestion phase is independent — a failure in one source must
        // not prevent the others from contributing data to the snapshot.
        var phaseErrors: [String] = []
        var remoteStatuses: [RemoteSyncStatus] = []

        let cache: CacheStore
        do {
            cache = try CacheStore(path: cachePath)
        } catch {
            return Result(snapshot: .empty,
                          errorMessage: PathScrubber.scrub("Cache init failed: \(error)"),
                          remoteStatuses: [])
        }

        let parser = EventsJSONLParser()
        let localChatReader = VSCodeChatReader()

        // ----- Local sources -----
        do {
            try ingestEventsJSONL(
                into: cache, parser: parser,
                vsCodeIds: localChatReader.knownSessionIds(),
                dir: sessionStateDir,
                remoteName: nil
            )
        } catch {
            phaseErrors.append(PathScrubber.scrub("Copilot events: \(error)"))
        }

        do {
            try ingestVSCodeChat(into: cache, reader: localChatReader, remoteName: nil)
        } catch {
            phaseErrors.append(PathScrubber.scrub("VS Code Chat: \(error)"))
        }

        // ----- Remote sources (over SSH/rsync) -----
        for remote in remotes {
            let outcome = RemoteSSHSyncer.sync(remote)
            var hostErrors = outcome.errors
            for e in outcome.errors {
                phaseErrors.append("\(remote.name): \(PathScrubber.scrub(e))")
            }

            if outcome.pulledSessionState {
                let dir = RemoteSSHSyncer.sessionStateMirror(for: remote)
                do {
                    try ingestEventsJSONL(
                        into: cache, parser: parser,
                        vsCodeIds: [], dir: dir, remoteName: remote.name
                    )
                } catch {
                    let msg = "events: \(PathScrubber.scrub("\(error)"))"
                    hostErrors.append(msg)
                    phaseErrors.append("\(remote.name) \(msg)")
                }
            }

            if outcome.pulledVscodeChatDb {
                let dbPath = RemoteSSHSyncer.vscodeChatDbPath(for: remote).path
                let remoteReader = VSCodeChatReader(path: dbPath)
                do {
                    try ingestVSCodeChat(into: cache, reader: remoteReader, remoteName: remote.name)
                } catch {
                    let msg = "chat: \(PathScrubber.scrub("\(error)"))"
                    hostErrors.append(msg)
                    phaseErrors.append("\(remote.name) \(msg)")
                }
            }

            let phase: RemoteSyncStatus.Phase = (outcome.errors.isEmpty && hostErrors.count == outcome.errors.count)
                ? .success
                : .failed
            remoteStatuses.append(RemoteSyncStatus(
                host: remote.name,
                phase: phase,
                lastSyncedAt: phase == .success ? Date() : nil,
                lastError: hostErrors.first
            ))
        }

        let records = (try? cache.allRecords()) ?? []
        let snap = UsageAggregator().snapshot(records: records)
        return Result(snapshot: snap, errorMessage: phaseErrors.first, remoteStatuses: remoteStatuses)
    }

    private static func ingestEventsJSONL(
        into cache: CacheStore,
        parser: EventsJSONLParser,
        vsCodeIds: Set<String>,
        dir: URL,
        remoteName: String?
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }

        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for sessionDir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
            guard fm.fileExists(atPath: eventsFile.path) else { continue }

            let state = try cache.fileState(filePath: eventsFile.path)

            if let s = state, s.sessionEnded,
               let attrs = try? fm.attributesOfItem(atPath: eventsFile.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value,
               s.byteOffset >= size {
                continue
            }

            let sessionId = sessionDir.lastPathComponent
            let source: UsageRecord.Source = vsCodeIds.contains(sessionId) ? .vscodeAgent : .copilotCLI

            var resumeFrom = state?.byteOffset ?? 0
            if let attrs = try? fm.attributesOfItem(atPath: eventsFile.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value,
               resumeFrom > size {
                resumeFrom = 0
            }

            let parsed = try parser.parse(
                file: eventsFile,
                fromByteOffset: resumeFrom,
                source: source,
                remoteName: remoteName
            )
            for r in parsed.records {
                let kind: CacheStore.RecordKind = (r.requestCount > 0) ? .message : .shutdown
                try cache.insertRecord(r, kind: kind)
            }
            try cache.updateFileState(
                filePath: eventsFile.path,
                sessionId: parsed.sessionId,
                byteOffset: parsed.lastByteOffset,
                sessionEnded: parsed.sessionEnded || (state?.sessionEnded ?? false),
                lastEventAt: parsed.lastEventAt ?? state?.lastEventAt
            )
        }
    }

    private static func ingestVSCodeChat(into cache: CacheStore, reader: VSCodeChatReader, remoteName: String?) throws {
        guard reader.hasExpectedSchema() else { return }
        try cache.clearChatRecords(remoteName: remoteName)
        let interactions = reader.chatInteractions(remoteName: remoteName)
        for r in interactions {
            try cache.insertRecord(r, kind: .chat)
        }
    }
}
