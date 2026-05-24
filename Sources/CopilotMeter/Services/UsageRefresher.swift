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
    /// Independent slow-cadence timer for remote refresh.
    private var remoteTimer: Timer?
    /// Set when refresh(includeRemotes:) was called while another refresh was
    /// in flight. We rerun with remotes as soon as the current refresh finishes.
    private var pendingIncludeRemotes: Bool = false

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
        // Kick off the first remote sync ~10 s after launch, giving the local
        // refresh comfortable headroom to complete first.
        if !enabledRemotes.isEmpty {
            scheduleRemoteRefresh(after: 10)
        }
    }

    /// Independent slow-cadence timer for remote refresh.

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
        if isRefreshing {
            // Another refresh is in flight. If the caller wanted remote data
            // and the in-flight refresh might not include it, remember to
            // re-run as soon as the current one finishes.
            if includeRemotes { pendingIncludeRemotes = true }
            return
        }
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
                // If a remote refresh was requested while we were busy with a
                // local-only refresh, run it now.
                if self.pendingIncludeRemotes {
                    self.pendingIncludeRemotes = false
                    self.refresh(includeRemotes: true)
                }
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

        // v0.1.6 migration: the CacheStore initializer wipes legacy
        // transcript records (so the next refresh re-classifies them as
        // Chat vs Agent). We also need to wipe the per-host `offsets.json`
        // so the remote extractor re-emits user.message events. The key is
        // versioned alongside the CacheStore migration so a bug-fix bump
        // re-triggers both halves of the migration in lockstep.
        let migrationKey = "v016_split_transcript_agent_remote_offsets_v2"
        if !cache.migrationDone(migrationKey) {
            let remotesRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CopilotMeter/remotes")
            if let contents = try? FileManager.default.contentsOfDirectory(at: remotesRoot, includingPropertiesForKeys: nil) {
                for dir in contents {
                    let offsetsPath = dir.appendingPathComponent("offsets.json")
                    try? FileManager.default.removeItem(at: offsetsPath)
                }
            }
            cache.markMigrationDone(migrationKey)
        }

        let parser = EventsJSONLParser()
        let localChatReader = VSCodeChatReader()
        let localTranscriptsReader = VSCodeChatTranscriptsReader(cache: cache)

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

        // VS Code Chat workspace transcripts must run BEFORE the central DB
        // ingest so the DB step can use the per-session transcript counts to
        // skip overlapping sessions.
        do {
            _ = try localTranscriptsReader.ingest(remoteName: nil)
        } catch {
            phaseErrors.append(PathScrubber.scrub("VS Code Chat transcripts: \(error)"))
        }

        do {
            try ingestVSCodeChat(into: cache, reader: localChatReader, remoteName: nil)
        } catch {
            phaseErrors.append(PathScrubber.scrub("VS Code Chat: \(error)"))
        }

        // ----- Remote sources (streamed extractor over SSH) -----
        let extractorScript = remoteExtractorScriptPath()

        for remote in remotes {
            var hostErrors: [String] = []
            var success = false

            // 1. Pull the small streamed extractor output (CLI events +
            //    workspace transcript user.message events). Buffer in memory
            //    so we can ingest after we know the central DB's classification.
            let extractResult: RemoteSSHExtractor.ExtractResult?
            do {
                extractResult = try RemoteSSHExtractor.extract(remote, scriptPath: extractorScript)
                success = true
            } catch {
                let msg = "extract: \(PathScrubber.scrub("\(error)"))"
                hostErrors.append(msg)
                phaseErrors.append("\(remote.name) \(msg)")
                extractResult = nil
            }

            // 2. Pull the central VS Code Chat DB (rsync). Needed for:
            //    (a) classifying events.jsonl sessions as .vscodeAgent
            //    (b) covering legacy sessions absent from per-workspace transcripts.
            let pulledChat = RemoteSSHExtractor.pullVscodeChatDb(remote)
            var remoteVsCodeIds: Set<String> = []
            if pulledChat {
                let dbPath = RemoteSSHExtractor.vscodeChatDbPath(for: remote).path
                remoteVsCodeIds = VSCodeChatReader(path: dbPath).knownSessionIds()
            }

            // 3. Ingest the extracted events now that we have DB classification
            //    info. Transcript user.message events land as
            //    (source=.vscodeChat, kind=.message) so the next step can dedup.
            if let extractResult {
                do {
                    try ingestExtractedEvents(
                        extractResult.events,
                        into: cache,
                        remoteName: remote.name,
                        remoteVsCodeIds: remoteVsCodeIds
                    )
                } catch {
                    let msg = "ingest: \(PathScrubber.scrub("\(error)"))"
                    hostErrors.append(msg)
                    phaseErrors.append("\(remote.name) \(msg)")
                    success = false
                }
            }

            // 4. Ingest the central DB chat rows, skipping any session whose
            //    per-workspace transcript already covered it as much or more.
            if pulledChat {
                let dbPath = RemoteSSHExtractor.vscodeChatDbPath(for: remote).path
                let remoteReader = VSCodeChatReader(path: dbPath)
                do {
                    try ingestVSCodeChat(into: cache, reader: remoteReader, remoteName: remote.name)
                } catch {
                    let msg = "chat: \(PathScrubber.scrub("\(error)"))"
                    hostErrors.append(msg)
                    phaseErrors.append("\(remote.name) \(msg)")
                }
            }

            let phase: RemoteSyncStatus.Phase = success ? .success : .failed
            remoteStatuses.append(RemoteSyncStatus(
                host: remote.name,
                phase: phase,
                lastSyncedAt: success ? Date() : nil,
                lastError: hostErrors.first
            ))
        }

        let records = (try? cache.allRecords()) ?? []
        let snap = UsageAggregator().snapshot(records: records)
        return Result(snapshot: snap, errorMessage: phaseErrors.first, remoteStatuses: remoteStatuses)
    }

    /// Locates `remote_extract.py` inside the .app bundle. Falls back to a
    /// dev-time path under the source tree when running unbundled.
    private static func remoteExtractorScriptPath() -> String {
        // 1. Inside an .app bundle, Bundle.main.resourcePath is Contents/Resources.
        if let bundlePath = Bundle.main.path(forResource: "remote_extract", ofType: "py") {
            return bundlePath
        }
        if let rp = Bundle.main.resourcePath {
            let candidate = "\(rp)/remote_extract.py"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        // 2. Running unbundled (e.g. `swift run`): try the source-tree
        // Resources/ dir relative to the executable.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let exeURL = URL(fileURLWithPath: exe).deletingLastPathComponent()
        let devCandidate = exeURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/remote_extract.py")
        if FileManager.default.fileExists(atPath: devCandidate.path) { return devCandidate.path }
        // 3. Last resort: a fixed path checked into the repo.
        return "/usr/local/share/copilotmeter/remote_extract.py"
    }

    /// Hydrates `UsageRecord`s from the JSONL stream returned by
    /// `RemoteSSHExtractor.extract`, then inserts them.
    ///
    /// Classification of each event.jsonl session uses two signals from the
    /// session.start payload:
    ///
    ///   1. `context.hostType == "github"` → GitHub Copilot **Cloud Agent** (the
    ///      cloud-dispatched agent fired off from a PR or VS Code's "Delegate"
    ///      feature).  → `.codingAgent` (rawValue kept for cache stability;
    ///      user-facing label is "Cloud Agent").
    ///   2. session_id present in the remote's VS Code Copilot Chat DB
    ///      `sessions` table → VS Code Copilot Chat in agent mode. → `.vscodeAgent`
    ///   3. Otherwise → terminal `copilot` CLI. → `.copilotCLI`
    private static func ingestExtractedEvents(
        _ events: [RemoteSSHExtractor.ExtractedEvent],
        into cache: CacheStore,
        remoteName: String,
        remoteVsCodeIds: Set<String>
    ) throws {
        // First pass: collect per-session metadata (selectedModel, hostType)
        // and which transcript sessions exhibited tool calls (= Agent mode).
        var sessionModel: [String: String] = [:]
        var sessionHostType: [String: String] = [:]
        var agentTranscriptSessions: Set<String> = []
        for e in events {
            switch e {
            case .sessionInfo(let sid, _, let sm, let ht):
                if let sm { sessionModel[sid] = sm }
                if let ht { sessionHostType[sid] = ht }
            case .workspaceAgentMarker(let sid):
                agentTranscriptSessions.insert(sid)
            default:
                break
            }
        }

        // Backfill: for sessions whose selectedModel we now know, sweep any
        // previously-ingested "unknown" message rows for that session. This
        // recovers history once Python re-emits init for sessions whose
        // session.start was already past the resume offset.
        for (sid, model) in sessionModel {
            try cache.backfillUnknownModel(sessionId: sid, remoteName: remoteName, model: model)
        }

        func classify(_ sid: String) -> UsageRecord.Source {
            if sessionHostType[sid] == "github" { return .codingAgent }
            if remoteVsCodeIds.contains(sid) { return .vscodeAgent }
            return .copilotCLI
        }

        for e in events {
            switch e {
            case .assistantMessage(let sid, let ts, let model, let messageId, let outputTokens):
                let resolvedModel = model ?? sessionModel[sid] ?? "unknown"
                let rec = UsageRecord(
                    timestamp: ts, sessionId: sid, messageId: messageId,
                    source: classify(sid), model: resolvedModel,
                    outputTokens: outputTokens,
                    inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                    requestCount: 1, premiumCost: nil, remoteName: remoteName
                )
                try cache.insertRecord(rec, kind: .message)

            case .sessionShutdownRow(let sid, let ts, let model, let input, let cr, let cw, let cost, let aiuNano):
                if input == 0 && cr == 0 && cw == 0 && cost == nil && aiuNano == nil { continue }
                let rec = UsageRecord(
                    timestamp: ts, sessionId: sid, messageId: nil,
                    source: classify(sid), model: model,
                    outputTokens: 0,
                    inputTokens: input, cacheReadTokens: cr, cacheWriteTokens: cw,
                    requestCount: 0, premiumCost: cost,
                    aiCreditsNano: aiuNano,
                    remoteName: remoteName
                )
                try cache.insertRecord(rec, kind: .shutdown)

            case .workspaceChatTurn(let sid, let ts, let messageId):
                // Default to .vscodeChat; reclassification below promotes
                // sessions with tool calls to .vscodeAgent.
                let source: UsageRecord.Source = agentTranscriptSessions.contains(sid)
                    ? .vscodeAgent : .vscodeChat
                let rec = UsageRecord(
                    timestamp: ts, sessionId: sid, messageId: messageId,
                    source: source, model: "GitHub Copilot Chat",
                    outputTokens: 0,
                    inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
                    requestCount: 1, premiumCost: nil, remoteName: remoteName
                )
                try cache.insertRecord(rec, kind: .message)

            case .sessionInfo, .sessionEnded, .fileOffset, .transcriptOffset, .workspaceAgentMarker:
                break
            }
        }

        // Retroactively reclassify rows from PREVIOUS runs that we ingested
        // as .vscodeChat before we knew the session had tool calls. New rows
        // already used the correct source above.
        if !agentTranscriptSessions.isEmpty {
            try cache.reclassifyTranscriptChatAsAgent(
                sessionIds: agentTranscriptSessions,
                remoteName: remoteName
            )
        }
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

        // One-shot AIU back-fill for sessions whose `session.shutdown` row
        // was ingested by a pre-AIU build. We force a rescan-from-offset-0
        // for these files exactly once per cache so we can pick up
        // `totalNanoAiu`. After that, the regular incremental scan keeps up.
        let aiuBackfillKey = "v017_aiu_backfill_done"
        let aiuBackfillNeeded = !cache.migrationDone(aiuBackfillKey)
        let missingAiuSessions: Set<String> = aiuBackfillNeeded
            ? Set((try? cache.localShutdownSessionsMissingAiu()) ?? [])
            : []

        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for sessionDir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
            guard fm.fileExists(atPath: eventsFile.path) else { continue }

            let state = try cache.fileState(filePath: eventsFile.path)
            let sessionId = sessionDir.lastPathComponent
            let needsAiuBackfill = missingAiuSessions.contains(sessionId)

            if let s = state, s.sessionEnded, !needsAiuBackfill,
               let attrs = try? fm.attributesOfItem(atPath: eventsFile.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value,
               s.byteOffset >= size {
                continue
            }

            // Initial guess: if the session ID appears in the local VS Code
            // Chat DB, it's an agent-mode VS Code session; otherwise CLI.
            // hostType (parsed below) may override this.
            let initialSource: UsageRecord.Source = vsCodeIds.contains(sessionId) ? .vscodeAgent : .copilotCLI

            // When back-filling AIU for an already-finished session, parse the
            // file from offset 0 so the session.shutdown line is re-seen. The
            // INSERT OR IGNORE + UPDATE-when-larger logic in `insertRecord`
            // makes the rescan idempotent for all other rows.
            var resumeFrom = needsAiuBackfill ? 0 : (state?.byteOffset ?? 0)
            if let attrs = try? fm.attributesOfItem(atPath: eventsFile.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value,
               resumeFrom > size {
                resumeFrom = 0
            }

            let parsed = try parser.parse(
                file: eventsFile,
                fromByteOffset: resumeFrom,
                source: initialSource,
                remoteName: remoteName
            )

            // hostType=github → this is a GitHub Copilot Cloud Agent session
            // (cloud-dispatched, e.g. via /delegate). Override the source.
            let finalSource: UsageRecord.Source = (parsed.hostType == "github") ? .codingAgent : initialSource

            // Backfill: if we now know this session's selectedModel, sweep any
            // previously-ingested "unknown" message rows for it. This recovers
            // history for sessions whose session.start sits before the resume
            // offset (and whose per-message events don't include `model`).
            if let sm = parsed.selectedModel, !sm.isEmpty {
                try cache.backfillUnknownModel(sessionId: parsed.sessionId, remoteName: remoteName, model: sm)
            }

            for r in parsed.records {
                let record: UsageRecord
                if finalSource == r.source {
                    record = r
                } else {
                    record = UsageRecord(
                        timestamp: r.timestamp,
                        sessionId: r.sessionId,
                        messageId: r.messageId,
                        source: finalSource,
                        model: r.model,
                        outputTokens: r.outputTokens,
                        inputTokens: r.inputTokens,
                        cacheReadTokens: r.cacheReadTokens,
                        cacheWriteTokens: r.cacheWriteTokens,
                        requestCount: r.requestCount,
                        premiumCost: r.premiumCost,
                        aiCreditsNano: r.aiCreditsNano,
                        remoteName: r.remoteName
                    )
                }
                let kind: CacheStore.RecordKind = (record.requestCount > 0) ? .message : .shutdown
                try cache.insertRecord(record, kind: kind)
            }
            try cache.updateFileState(
                filePath: eventsFile.path,
                sessionId: parsed.sessionId,
                byteOffset: parsed.lastByteOffset,
                sessionEnded: parsed.sessionEnded || (state?.sessionEnded ?? false),
                lastEventAt: parsed.lastEventAt ?? state?.lastEventAt
            )
        }

        // One-shot AIU back-fill done — flag it so future refreshes skip the
        // expensive rescan-from-zero pass.
        if aiuBackfillNeeded {
            cache.markMigrationDone(aiuBackfillKey)
        }
    }

    private static func ingestVSCodeChat(into cache: CacheStore, reader: VSCodeChatReader, remoteName: String?) throws {
        guard reader.hasExpectedSchema() else { return }
        try cache.clearChatRecords(remoteName: remoteName)

        let interactions = reader.chatInteractions(remoteName: remoteName)

        // De-dup against per-workspace transcript records (kind=msg,
        // source=vscodeChat) so we don't double-count sessions that appear in
        // BOTH the central DB and the workspace transcripts.
        //
        // Per-session rule: final count per session = max(tx, db).
        // Implementation: insert only `max(0, db - tx)` central-DB rows per
        // session. The DB rows have message_id = NULL and SQLite treats NULLs
        // as distinct for UNIQUE, so multiple count-only rows per session are
        // allowed. We keep the most-recent DB rows for stable timestamps.
        let txCounts = (try? cache.chatTranscriptSessionCounts(remoteName: remoteName)) ?? [:]

        // Bucket DB rows by session, sorted by timestamp descending so we can
        // drop the oldest rows when dedup'ing.
        var bySession: [String: [UsageRecord]] = [:]
        for r in interactions {
            bySession[r.sessionId, default: []].append(r)
        }

        for (sid, rows) in bySession {
            let dbCount = rows.count
            let txCount = txCounts[sid] ?? 0
            let toKeep = max(0, dbCount - txCount)
            if toKeep == 0 { continue }
            // Keep the most recent `toKeep` rows so the timestamp distribution
            // stays meaningful for the daily/weekly views.
            let sorted = rows.sorted { $0.timestamp > $1.timestamp }
            for r in sorted.prefix(toKeep) {
                try cache.insertRecord(r, kind: .chat)
            }
        }
    }
}
