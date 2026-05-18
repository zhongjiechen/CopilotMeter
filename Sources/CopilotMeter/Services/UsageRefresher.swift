import Foundation
import Combine

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

    private let sessionStateDir: URL
    private let cachePath: String

    private var timer: Timer?
    private var inFlight: Task<Void, Never>?

    public init(sessionStateDir: URL? = nil, cachePath: String = CacheStore.defaultPath) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionStateDir = sessionStateDir ?? home.appendingPathComponent(".copilot/session-state")
        self.cachePath = cachePath
    }

    public func startAutoRefresh(every seconds: TimeInterval = 60) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    public func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let dir = self.sessionStateDir
        let cachePath = self.cachePath
        inFlight?.cancel()
        inFlight = Task.detached(priority: .utility) {
            let result = RefreshWorker.run(cachePath: cachePath, sessionStateDir: dir)
            await MainActor.run {
                self.snapshot = result.snapshot
                self.lastError = result.errorMessage
                self.lastRefreshAt = Date()
                self.isRefreshing = false
            }
        }
    }
}

/// Detached worker that does all blocking IO. All values used here are Sendable
/// (Strings, URLs, and types we control). The worker does not reach back into
/// the @MainActor refresher.
enum RefreshWorker {
    struct Result: Sendable {
        let snapshot: UsageAggregator.Snapshot
        let errorMessage: String?
    }

    static func run(cachePath: String, sessionStateDir: URL) -> Result {
        // Each ingestion phase is independent — a failure in one source must
        // not prevent the other from contributing data to the snapshot.
        // We collect any non-fatal errors and surface the first one to the UI.
        var phaseErrors: [String] = []

        let cache: CacheStore
        do {
            cache = try CacheStore(path: cachePath)
        } catch {
            return Result(snapshot: .empty,
                          errorMessage: PathScrubber.scrub("Cache init failed: \(error)"))
        }

        let parser = EventsJSONLParser()
        let chatReader = VSCodeChatReader()

        do {
            try ingestEventsJSONL(into: cache, parser: parser, chatReader: chatReader, dir: sessionStateDir)
        } catch {
            phaseErrors.append(PathScrubber.scrub("Copilot events: \(error)"))
        }

        do {
            try ingestVSCodeChat(into: cache, reader: chatReader)
        } catch {
            phaseErrors.append(PathScrubber.scrub("VS Code Chat: \(error)"))
        }

        let records = (try? cache.allRecords()) ?? []
        let snap = UsageAggregator().snapshot(records: records)
        return Result(snapshot: snap, errorMessage: phaseErrors.first)
    }

    private static func ingestEventsJSONL(
        into cache: CacheStore,
        parser: EventsJSONLParser,
        chatReader: VSCodeChatReader,
        dir: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        // knownSessionIds() no longer throws — it returns [] for a missing or
        // unfamiliar VS Code Copilot Chat DB.
        let vsCodeIds = chatReader.knownSessionIds()

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

            let parsed = try parser.parse(file: eventsFile, fromByteOffset: resumeFrom, source: source)
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

    private static func ingestVSCodeChat(into cache: CacheStore, reader: VSCodeChatReader) throws {
        guard reader.hasExpectedSchema() else { return }
        try cache.clearChatRecords()
        let interactions = reader.chatInteractions()
        for r in interactions {
            try cache.insertRecord(r, kind: .chat)
        }
    }
}
