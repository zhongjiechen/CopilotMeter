import Foundation

/// One remote machine whose Copilot data we want to mirror locally over SSH.
///
/// We pull from up to two locations on the remote:
///
///   - `session_state_dir` (default `~/.copilot/session-state`) — Copilot CLI
///     and VS Code Copilot agent sessions. Has full token / cache data.
///
///   - `vscode_chat_db_dir` (default
///     `~/.vscode-server/data/User/globalStorage/github.copilot-chat`) —
///     VS Code Copilot Chat sessions (the "Ask" panel) when VS Code is
///     running via Remote-SSH. Counts-only (no token data per turn).
///
/// Either can be set to "" to disable that source for the host.
public struct RemoteHost: Codable, Sendable, Identifiable {
    /// User-chosen nickname (used as a folder name and displayed in the UI).
    public let name: String
    /// What you'd type after `ssh ` — e.g. `"chenzhj@workstation"` or just
    /// `"workstation"` if your ~/.ssh/config takes care of it.
    public let sshHost: String
    /// Absolute or `~/`-prefixed path on the remote. Empty string disables.
    public let sessionStateDir: String
    /// Directory containing the VS Code Copilot Chat session-store.db (we
    /// pull only the .db file). Empty string disables.
    public let vscodeChatDbDir: String
    /// Optional path to a private key (rare; ssh-agent + ~/.ssh/config is
    /// usually sufficient). Forwarded to rsync as `-e "ssh -i <path>"`.
    public let identityFile: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case sshHost = "ssh_host"
        case sessionStateDir = "session_state_dir"
        case vscodeChatDbDir = "vscode_chat_db_dir"
        case identityFile = "identity_file"
    }

    public init(
        name: String,
        sshHost: String,
        sessionStateDir: String = "~/.copilot/session-state",
        vscodeChatDbDir: String = "~/.vscode-server/data/User/globalStorage/github.copilot-chat",
        identityFile: String? = nil
    ) {
        self.name = name
        self.sshHost = sshHost
        self.sessionStateDir = sessionStateDir
        self.vscodeChatDbDir = vscodeChatDbDir
        self.identityFile = identityFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.sshHost = try c.decode(String.self, forKey: .sshHost)
        self.sessionStateDir = (try? c.decode(String.self, forKey: .sessionStateDir))
            ?? "~/.copilot/session-state"
        self.vscodeChatDbDir = (try? c.decode(String.self, forKey: .vscodeChatDbDir))
            ?? "~/.vscode-server/data/User/globalStorage/github.copilot-chat"
        self.identityFile = try? c.decode(String.self, forKey: .identityFile)
    }
}

/// Top-level layout of ~/Library/Application Support/CopilotMeter/remotes.json.
///
/// Minimal example:
/// ```json
/// {
///   "remotes": [
///     { "name": "workstation", "ssh_host": "chenzhj@workstation" }
///   ]
/// }
/// ```
///
/// All-keys example:
/// ```json
/// {
///   "remotes": [
///     {
///       "name": "l40",
///       "ssh_host": "yangz@l40",
///       "session_state_dir": "/home/yangz/.copilot/session-state",
///       "vscode_chat_db_dir": "/home/yangz/.vscode-server/data/User/globalStorage/github.copilot-chat",
///       "identity_file": "~/.ssh/id_ed25519"
///     }
///   ]
/// }
/// ```
public struct RemotesConfig: Codable, Sendable {
    public let remotes: [RemoteHost]

    public static let empty = RemotesConfig(remotes: [])

    public init(remotes: [RemoteHost]) {
        self.remotes = remotes
    }

    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/CopilotMeter/remotes.json"
    }

    /// Reads the config from `defaultPath`. Returns `.empty` (silently) when:
    ///   - the file doesn't exist (the common case)
    ///   - the file exists but is malformed JSON — a warning is captured for the UI
    public static func load(from path: String = defaultPath) -> (RemotesConfig, String?) {
        guard FileManager.default.fileExists(atPath: path) else { return (.empty, nil) }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let cfg = try JSONDecoder().decode(RemotesConfig.self, from: data)
            return (cfg, nil)
        } catch {
            return (.empty, "remotes.json is invalid: \(error.localizedDescription)")
        }
    }

    /// Persists the config to `defaultPath` (creating the parent directory if
    /// needed). Throws on IO/encoding errors.
    public func save(to path: String = defaultPath) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }
}
