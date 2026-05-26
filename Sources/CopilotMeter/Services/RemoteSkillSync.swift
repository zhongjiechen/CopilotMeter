import Foundation

/// One-shot push of the local `~/.copilot/skills` and `~/.copilot/agents`
/// directories to a remote host via `rsync` over SSH.
///
/// Why we expose this:
///   - Skills and agent definitions live as plain files under `~/.copilot/`,
///     so people who edit them locally (in their editor of choice) want a
///     painless way to mirror them to dev boxes / remote workstations where
///     they also run Copilot CLI.
///   - We already know about the user's remotes (via `RemoteHost`) and have
///     a working SSH path through `BatchMode=yes` + `~/.ssh/config`, so a
///     one-button rsync is a natural extension.
///
/// Behavior:
///   - Pushes **both** directories. If one is missing locally we skip it
///     silently (no `--delete` against a non-existent source — that would
///     wipe the remote).
///   - Uses `rsync -a --delete` so the remote becomes a byte-for-byte
///     mirror of the local copy. Trailing slash on the source means
///     "contents of the dir, not the dir itself".
///   - Pre-creates the remote parent dir (`~/.copilot`) via
///     `--rsync-path="mkdir -p <parent> && rsync"` so a fresh remote
///     without `.copilot/` doesn't fail.
///   - Honors `remote.identityFile` if set, matching the rest of the app.
///   - Runs in the background; results surface via the `Outcome` value
///     returned to the caller (which `UsageRefresher` publishes for the UI).
public enum RemoteSkillSync {

    public struct DirResult: Sendable, Equatable {
        public enum Status: String, Sendable, Equatable {
            /// rsync exit 0; remote now mirrors local.
            case synced
            /// local dir doesn't exist; skipped (not an error).
            case skipped
            /// rsync exit non-zero; remote NOT updated. See `error`.
            case failed
        }
        public let dirName: String
        public let status: Status
        public let bytesTransferred: Int64
        public let filesTransferred: Int
        /// One-line error summary on `.failed`, nil otherwise.
        public let error: String?
    }

    public struct Outcome: Sendable, Equatable {
        public let host: String
        public let results: [DirResult]
        public let durationSeconds: Double

        public var allSucceeded: Bool {
            results.allSatisfy { $0.status != .failed }
        }
        public var hasAnyTransfer: Bool {
            results.contains { $0.status == .synced }
        }
        public var combinedError: String? {
            let errs = results.compactMap { $0.error }
            return errs.isEmpty ? nil : errs.joined(separator: " · ")
        }
    }

    /// One sync target: local dir → remote path, with a short human label.
    public struct Target: Sendable, Equatable {
        public let label: String       // e.g. "skills", shown in UI
        public let localDir: URL       // e.g. ~/.copilot/skills
        public let remotePath: String  // e.g. "~/.copilot/skills"
    }

    /// Locations on the local Mac → corresponding locations on the remote.
    /// Exposed so tests can override.
    ///
    /// Any target whose `localDir` doesn't exist on the Mac is silently
    /// skipped (we never `--delete` against a missing source).
    public static var defaultTargets: [Target] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Target(label: "skills",
                   localDir: home.appendingPathComponent(".copilot/skills"),
                   remotePath: "~/.copilot/skills"),
            Target(label: "agents",
                   localDir: home.appendingPathComponent(".copilot/agents"),
                   remotePath: "~/.copilot/agents"),
        ]
    }()

    /// Synchronous push (must be called off the main thread — rsync can
    /// take seconds on first sync to a slow link, even though our payloads
    /// are typically <1 MB).
    public static func push(to remote: RemoteHost,
                            targets: [Target] = defaultTargets) -> Outcome {
        let start = Date()
        var results: [DirResult] = []

        for target in targets {
            results.append(rsyncOne(remote: remote, target: target))
        }

        return Outcome(
            host: remote.name,
            results: results,
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    // MARK: - internals

    private static func rsyncOne(remote: RemoteHost, target: Target) -> DirResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.localDir.path, isDirectory: &isDir), isDir.boolValue else {
            return DirResult(dirName: target.label, status: .skipped,
                             bytesTransferred: 0, filesTransferred: 0,
                             error: nil)
        }

        // Trailing slash on src → copy *contents* of the dir, so the remote
        // dir's contents match the source dir's contents.
        let src = target.localDir.path.hasSuffix("/") ? target.localDir.path : target.localDir.path + "/"
        let dest = "\(remote.sshHost):\(target.remotePath)/"

        // Parent dir on the remote — pre-create via --rsync-path so a fresh
        // remote that doesn't yet have `~/.claude/` or `~/.copilot/` works.
        let remoteParent = (target.remotePath as NSString).deletingLastPathComponent

        var sshCmd = "ssh -o BatchMode=yes -o ConnectTimeout=8"
        if let key = remote.identityFile, !key.isEmpty {
            sshCmd += " -i \(shellEscape(key))"
        }

        let proc = Process()
        proc.launchPath = "/usr/bin/rsync"
        proc.arguments = [
            "-a", "--delete",
            // Don't try to chown / chgrp on the remote — the user may not
            // have permission and we don't care about file ownership.
            "--no-perms", "--no-owner", "--no-group",
            // Skip macOS-specific cruft. ._* files (AppleDouble) and
            // .DS_Store would otherwise pollute the remote with files the
            // CLI doesn't understand.
            "--exclude", ".DS_Store",
            "--exclude", "._*",
            // Stats line at the end is parsed below for the UI.
            "--stats",
            // Pre-create the remote parent dir (no-op if already there).
            // This is portable across rsync versions, unlike --mkpath
            // which only exists in rsync 3.2.3+.
            "--rsync-path", "mkdir -p \(remoteParent) && rsync",
            "-e", sshCmd,
            src,
            dest,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return DirResult(dirName: target.label, status: .failed,
                             bytesTransferred: 0, filesTransferred: 0,
                             error: "couldn't launch rsync: \(error.localizedDescription)")
        }

        let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let stderr = (String(data: errData, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .prefix(2)
                .joined(separator: " · ")
            return DirResult(dirName: target.label, status: .failed,
                             bytesTransferred: 0, filesTransferred: 0,
                             error: stderr.isEmpty
                                ? "rsync exit \(proc.terminationStatus)"
                                : "rsync exit \(proc.terminationStatus): \(stderr)")
        }

        let (bytes, files) = parseStats(String(data: outData, encoding: .utf8) ?? "")
        return DirResult(dirName: target.label, status: .synced,
                         bytesTransferred: bytes,
                         filesTransferred: files,
                         error: nil)
    }

    /// Pulls a `(bytes, files)` pair from rsync's `--stats` block.
    /// rsync's exact wording varies slightly across versions; we accept both:
    ///   "Number of regular files transferred: N"   (rsync 3.1+)
    ///   "Number of files transferred: N"           (older / stock macOS rsync)
    ///   "Total transferred file size: N bytes"
    /// We're lenient about which line is which.
    private static func parseStats(_ s: String) -> (Int64, Int) {
        var bytes: Int64 = 0
        var files: Int = 0
        for line in s.split(separator: "\n") {
            let l = String(line)
            if l.contains("files transferred:") {
                if let n = firstInt(in: l) { files = Int(n) }
            } else if l.contains("Total transferred file size:") {
                if let n = firstInt(in: l) { bytes = n }
            }
        }
        return (bytes, files)
    }

    private static func firstInt(in s: String) -> Int64? {
        // Match the first run of digits (possibly with commas).
        guard let range = s.range(of: "[0-9][0-9,]*", options: .regularExpression) else { return nil }
        let stripped = s[range].replacingOccurrences(of: ",", with: "")
        return Int64(stripped)
    }

    private static func shellEscape(_ s: String) -> String {
        if s.range(of: "[^A-Za-z0-9_./@~-]", options: .regularExpression) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
