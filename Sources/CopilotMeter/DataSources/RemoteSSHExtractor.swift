import Foundation

/// Pulls Copilot usage data from a remote host by streaming a small Python
/// extractor over SSH and reading back a compact JSONL stream of just the
/// token-relevant events. This is dramatically more efficient than rsync'ing
/// the entire events.jsonl tree: a 200 MB session-state directory typically
/// yields a ~3 MB stream on first run and ~1 KB on subsequent runs.
///
/// The extractor script (`Resources/remote_extract.py`) is shipped inside
/// the .app bundle so users don't need to install anything on the remote.
/// We just `ssh host 'python3 -' < extractor.py "<base64-offsets>"`.
///
/// VS Code Copilot Chat data (the SQLite DB) is small (a few MB), schema-
/// stable, and not amenable to streaming-style extraction, so we still
/// rsync that file when present.
public enum RemoteSSHExtractor {

    public struct ExtractOutcome {
        public let remote: String
        public let pulledSessionState: Bool
        public let pulledVscodeChatDb: Bool
        public let errors: [String]
        /// Approximate compressed bytes received from the remote (for the
        /// extractor stream). Useful for stats in the UI.
        public let extractorBytes: Int
    }

    /// Per-remote cache root mirrors the directory layout the rsync-based
    /// implementation used, so existing logic that reads from
    /// `mirrorRoot/vscode-chat/session-store.db` keeps working.
    public static func mirrorRoot(for remote: RemoteHost) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/CopilotMeter/remotes")
            .appendingPathComponent(remote.name)
    }
    public static func vscodeChatDbPath(for remote: RemoteHost) -> URL {
        mirrorRoot(for: remote)
            .appendingPathComponent("vscode-chat")
            .appendingPathComponent("session-store.db")
    }
    public static func offsetsCachePath(for remote: RemoteHost) -> URL {
        mirrorRoot(for: remote)
            .appendingPathComponent("offsets.json")
    }

    public enum ExtractError: Error, CustomStringConvertible {
        case scriptMissing
        case sshFailed(exitCode: Int32, stderr: String)
        case rsyncFailed(exitCode: Int32, stderr: String)
        public var description: String {
            switch self {
            case .scriptMissing:
                return "remote_extract.py not found in app bundle"
            case .sshFailed(let c, let s):
                let snippet = s.split(separator: "\n").prefix(2).joined(separator: " · ")
                return "ssh exit \(c)\(snippet.isEmpty ? "" : ": \(snippet)")"
            case .rsyncFailed(let c, let s):
                let snippet = s.split(separator: "\n").prefix(2).joined(separator: " · ")
                return "rsync exit \(c)\(snippet.isEmpty ? "" : ": \(snippet)")"
            }
        }
    }

    /// Parsed event payloads we re-hydrate into UsageRecords.
    public enum ExtractedEvent {
        case sessionInfo(sid: String, ts: Date, selectedModel: String?, hostType: String?)
        case sessionResumed(sid: String)
        case assistantMessage(sid: String, ts: Date, model: String?, messageId: String?, outputTokens: Int)
        case sessionShutdownRow(sid: String, ts: Date, lineOffset: Int64, model: String, inputTokens: Int, cacheRead: Int, cacheWrite: Int, premiumCost: Double?, aiCreditsNano: Int64?)
        case sessionEnded(sid: String)
        /// One VS Code Chat user.message turn from a workspaceStorage transcript.
        /// `sessionId` is the chat session UUID (filename of the .jsonl);
        /// `messageId` is the event's own UUID and is used for dedup.
        case workspaceChatTurn(sid: String, ts: Date, messageId: String)
        /// Stamps a transcript session as VS Code **Agent mode** (the
        /// extractor saw at least one `tool.execution_start` event for it).
        /// The ingest layer uses this to reclassify `workspaceChatTurn`
        /// rows for the same session from `.vscodeChat` to `.vscodeAgent`.
        case workspaceAgentMarker(sid: String)
        /// Resume marker for a CLI/Agent events.jsonl file (keyed by session id).
        case fileOffset(sid: String, byteOffset: Int64)
        /// Resume marker for a VS Code Chat transcript file (composite key
        /// `wsx:<workspaceHash>/<sessionId>` to disambiguate the same session
        /// id appearing in multiple workspaces).
        case transcriptOffset(key: String, byteOffset: Int64)
    }

    public struct ExtractResult {
        public let events: [ExtractedEvent]
        public let bytesReceived: Int
    }

    /// Runs the extractor on `remote` and returns parsed events.
    /// Persists the new offsets to `offsetsCachePath(for:)` on success so the
    /// next invocation only fetches new events.
    public static func extract(_ remote: RemoteHost, scriptPath: String) throws -> ExtractResult {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ExtractError.scriptMissing
        }
        try FileManager.default.createDirectory(at: mirrorRoot(for: remote), withIntermediateDirectories: true)

        let offsetsB64 = loadOffsetsAsBase64(for: remote)

        let sshCommand: String = {
            // ssh runs `python3 - '<base64-offsets>'`; our stdin to ssh becomes
            // python's stdin (= the script source).
            "python3 - '\(offsetsB64)'"
        }()

        var sshArgs: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
        ]
        if let key = remote.identityFile, !key.isEmpty {
            sshArgs.append(contentsOf: ["-i", key])
        }
        sshArgs.append(remote.sshHost)
        sshArgs.append(sshCommand)

        let proc = Process()
        proc.launchPath = "/usr/bin/ssh"
        proc.arguments = sshArgs

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()

        // Feed the script to ssh's stdin. Write in a background task so we
        // don't deadlock if the script output fills the pipe before we
        // finish writing.
        let scriptData = (try? Data(contentsOf: URL(fileURLWithPath: scriptPath))) ?? Data()
        DispatchQueue.global(qos: .utility).async {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: scriptData)
            } catch {}
            try? stdinPipe.fileHandleForWriting.close()
        }

        let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw ExtractError.sshFailed(exitCode: proc.terminationStatus, stderr: stderr)
        }

        let events = parseStream(outData)

        // Persist new offsets for the next run. Both CLI session offsets and
        // transcript composite-key offsets share the same dict — the keys are
        // disjoint by construction (transcript keys start with "wsx:").
        var newOffsets: [String: Int64] = [:]
        for e in events {
            switch e {
            case .fileOffset(let sid, let off):
                newOffsets[sid] = off
            case .transcriptOffset(let key, let off):
                newOffsets[key] = off
            default:
                break
            }
        }
        saveOffsets(newOffsets, for: remote)

        return ExtractResult(events: events, bytesReceived: outData.count)
    }

    /// Pulls the remote's VS Code Copilot Chat session-store.db via rsync.
    /// Returns true on success, false if the remote path doesn't exist or
    /// rsync fails (which we treat as non-fatal — the user simply hasn't used
    /// VS Code Chat on that machine).
    public static func pullVscodeChatDb(_ remote: RemoteHost) -> Bool {
        guard !remote.vscodeChatDbDir.isEmpty else { return false }
        let localDir = mirrorRoot(for: remote).appendingPathComponent("vscode-chat")
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        let src: String
        if remote.vscodeChatDbDir.hasSuffix("/") {
            src = "\(remote.sshHost):\(remote.vscodeChatDbDir)session-store.db"
        } else {
            src = "\(remote.sshHost):\(remote.vscodeChatDbDir)/session-store.db"
        }

        var sshCmd = "ssh -o BatchMode=yes -o ConnectTimeout=8"
        if let key = remote.identityFile, !key.isEmpty {
            sshCmd += " -i \(shellEscape(key))"
        }

        let proc = Process()
        proc.launchPath = "/usr/bin/rsync"
        proc.arguments = [
            "-a", "--no-perms", "--no-owner", "--no-group",
            "-e", sshCmd,
            src,
            localDir.path + "/"
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - parsing

    private static let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ s: String?) -> Date {
        guard let s else { return Date() }
        return iso8601Frac.date(from: s) ?? iso8601.date(from: s) ?? Date()
    }

    private static func parseStream(_ data: Data) -> [ExtractedEvent] {
        var out: [ExtractedEvent] = []
        var lineStart = 0
        let bytes = [UInt8](data)
        for i in 0..<bytes.count {
            guard bytes[i] == 0x0A else { continue }
            let lineBytes = Data(bytes[lineStart..<i])
            lineStart = i + 1
            guard !lineBytes.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any] else { continue }

            // Transcript progress marker (composite key).
            if let okey = obj["okey"] as? String,
               let off = obj["off"] as? Int {
                out.append(.transcriptOffset(key: okey, byteOffset: Int64(off)))
                continue
            }

            guard let sid = obj["sid"] as? String else { continue }

            if let off = obj["off"] as? Int {
                out.append(.fileOffset(sid: sid, byteOffset: Int64(off)))
                continue
            }
            let t = obj["t"] as? String
            switch t {
            case "init":
                let sm = obj["sm"] as? String
                let ht = obj["ht"] as? String
                out.append(.sessionInfo(
                    sid: sid,
                    ts: parseTimestamp(obj["ts"] as? String),
                    selectedModel: sm,
                    hostType: ht
                ))
            case "m":
                let outputTokens = (obj["out"] as? Int) ?? 0
                out.append(.assistantMessage(
                    sid: sid,
                    ts: parseTimestamp(obj["ts"] as? String),
                    model: obj["model"] as? String,
                    messageId: obj["mid"] as? String,
                    outputTokens: outputTokens
                ))
            case "resume":
                out.append(.sessionResumed(sid: sid))
            case "s":
                guard let model = obj["model"] as? String else { continue }
                let lineOffset: Int64?
                if let n = obj["soff"] as? Int64 {
                    lineOffset = n
                } else if let n = obj["soff"] as? Int {
                    lineOffset = Int64(n)
                } else if let d = obj["soff"] as? Double {
                    lineOffset = Int64(d)
                } else {
                    lineOffset = nil
                }
                guard let lineOffset else { continue }
                // `aiu` is the model's totalNanoAiu (nano-AIU integer).
                // Only present on session.shutdown rollups emitted by
                // newer Copilot CLI builds. Decode as Int64 so we don't
                // lose precision on big sessions (>2^31 nano-AIU).
                let aiuNano: Int64?
                if let n = obj["aiu"] as? Int64 {
                    aiuNano = n
                } else if let n = obj["aiu"] as? Int {
                    aiuNano = Int64(n)
                } else if let d = obj["aiu"] as? Double {
                    aiuNano = Int64(d)
                } else {
                    aiuNano = nil
                }
                out.append(.sessionShutdownRow(
                    sid: sid,
                    ts: parseTimestamp(obj["ts"] as? String),
                    lineOffset: lineOffset,
                    model: model,
                    inputTokens: (obj["in"] as? Int) ?? 0,
                    cacheRead: (obj["cr"] as? Int) ?? 0,
                    cacheWrite: (obj["cw"] as? Int) ?? 0,
                    premiumCost: (obj["cost"] as? Double),
                    aiCreditsNano: aiuNano
                ))
            case "end":
                out.append(.sessionEnded(sid: sid))
            case "wt":
                guard let mid = obj["mid"] as? String else { continue }
                out.append(.workspaceChatTurn(
                    sid: sid,
                    ts: parseTimestamp(obj["ts"] as? String),
                    messageId: mid
                ))
            case "wagent":
                out.append(.workspaceAgentMarker(sid: sid))
            default:
                break
            }
        }
        return out
    }

    // MARK: - offsets persistence

    private static func loadOffsetsAsBase64(for remote: RemoteHost) -> String {
        let path = offsetsCachePath(for: remote).path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return Data("{}".utf8).base64EncodedString()
        }
        return data.base64EncodedString()
    }

    private static func saveOffsets(_ offsets: [String: Int64], for remote: RemoteHost) {
        let path = offsetsCachePath(for: remote).path
        guard let data = try? JSONSerialization.data(withJSONObject: offsets) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    // MARK: - util

    private static func shellEscape(_ s: String) -> String {
        if s.range(of: "[^A-Za-z0-9_./@~-]", options: .regularExpression) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
