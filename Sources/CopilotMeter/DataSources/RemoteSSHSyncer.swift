import Foundation

/// Mirrors a remote host's Copilot data directories to a local directory
/// using `rsync` over SSH.
///
/// Per-host mirror layout (under `~/Library/Application Support/CopilotMeter/remotes/<name>/`):
///
///   ./session-state/<sid>/events.jsonl   <-- pulled from remote `session_state_dir`
///   ./vscode-chat/session-store.db       <-- pulled from remote `vscode_chat_db_dir`
///
/// We pull only the files we know how to parse. `events.jsonl` is
/// rsync-friendly (append-only); `session-store.db` is a SQLite file that
/// can be in the middle of a WAL transaction, but rsync's atomicity
/// guarantees a coherent snapshot if the file changes mid-transfer (worst
/// case: we re-pull next refresh).
public enum RemoteSSHSyncer {

    public struct SyncOutcome {
        public let remote: String
        public let pulledSessionState: Bool
        public let pulledVscodeChatDb: Bool
        public let errors: [String]   // human-readable, scrubbed of $HOME
    }

    /// Local directory mirroring the remote for a given remote.
    public static func mirrorRoot(for remote: RemoteHost) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/CopilotMeter/remotes")
            .appendingPathComponent(remote.name)
    }
    public static func sessionStateMirror(for remote: RemoteHost) -> URL {
        mirrorRoot(for: remote).appendingPathComponent("session-state")
    }
    public static func vscodeChatDbPath(for remote: RemoteHost) -> URL {
        mirrorRoot(for: remote)
            .appendingPathComponent("vscode-chat")
            .appendingPathComponent("session-store.db")
    }

    /// Pulls the host's enabled data sources. Each enabled source is run in
    /// isolation: a failure in one is reported but does not block the other.
    @discardableResult
    public static func sync(_ remote: RemoteHost) -> SyncOutcome {
        let fm = FileManager.default
        try? fm.createDirectory(at: mirrorRoot(for: remote), withIntermediateDirectories: true)

        var errors: [String] = []
        var pulledSession = false
        var pulledChatDb = false

        if !remote.sessionStateDir.isEmpty {
            do {
                try pullSessionState(remote)
                pulledSession = true
            } catch {
                errors.append("session-state: \(error)")
            }
        }
        if !remote.vscodeChatDbDir.isEmpty {
            do {
                try pullVscodeChatDb(remote)
                pulledChatDb = true
            } catch {
                errors.append("vscode-chat: \(error)")
            }
        }
        return SyncOutcome(
            remote: remote.name,
            pulledSessionState: pulledSession,
            pulledVscodeChatDb: pulledChatDb,
            errors: errors
        )
    }

    // MARK: - rsync runners

    private static func pullSessionState(_ remote: RemoteHost) throws {
        let local = sessionStateMirror(for: remote)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        let src = endsWithSlash(remote.sessionStateDir)
            ? "\(remote.sshHost):\(remote.sessionStateDir)"
            : "\(remote.sshHost):\(remote.sessionStateDir)/"

        try runRsync(
            args: [
                "-a", "--no-perms", "--no-owner", "--no-group",
                "--include=*/",            // recurse into per-session subdirs
                "--include=events.jsonl",  // pick up the events file
                "--exclude=*",             // ignore plan.md, files/, etc.
                "--prune-empty-dirs"
            ],
            identityFile: remote.identityFile,
            src: src,
            dst: local.path + "/"
        )
    }

    private static func pullVscodeChatDb(_ remote: RemoteHost) throws {
        let localDir = mirrorRoot(for: remote).appendingPathComponent("vscode-chat")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        let src = endsWithSlash(remote.vscodeChatDbDir)
            ? "\(remote.sshHost):\(remote.vscodeChatDbDir)session-store.db"
            : "\(remote.sshHost):\(remote.vscodeChatDbDir)/session-store.db"

        try runRsync(
            args: ["-a", "--no-perms", "--no-owner", "--no-group"],
            identityFile: remote.identityFile,
            src: src,
            dst: localDir.path + "/"
        )
    }

    // MARK: - low-level

    private static func runRsync(args extraArgs: [String], identityFile: String?, src: String, dst: String) throws {
        var sshCmd = "ssh -o BatchMode=yes -o ConnectTimeout=8"
        if let key = identityFile, !key.isEmpty {
            sshCmd += " -i \(shellEscape(key))"
        }

        var args: [String] = []
        args += extraArgs
        args += ["-e", sshCmd, src, dst]

        let proc = Process()
        proc.launchPath = "/usr/bin/rsync"
        proc.arguments = args

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            throw SyncError.launchFailed("\(error)")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.rsyncFailed(exitCode: proc.terminationStatus, stderr: stderr)
        }
    }

    public enum SyncError: Error, CustomStringConvertible {
        case launchFailed(String)
        case rsyncFailed(exitCode: Int32, stderr: String)

        public var description: String {
            switch self {
            case .launchFailed(let m): return "rsync failed to launch: \(m)"
            case .rsyncFailed(let c, let s):
                let snippet = s.split(separator: "\n").prefix(2).joined(separator: " · ")
                return "rsync exit \(c)\(snippet.isEmpty ? "" : ": \(snippet)")"
            }
        }
    }

    private static func endsWithSlash(_ s: String) -> Bool { s.hasSuffix("/") }

    private static func shellEscape(_ s: String) -> String {
        if s.range(of: "[^A-Za-z0-9_./@~-]", options: .regularExpression) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
