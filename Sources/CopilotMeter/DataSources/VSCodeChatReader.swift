import Foundation

/// Reads the VS Code Copilot Chat session-store DB to surface "ask mode" interactions
/// that do NOT appear in `~/.copilot/session-state/<id>/events.jsonl`.
///
/// Because the VS Code Chat DB only stores user/assistant text (no model name or
/// token counts), we emit one synthetic UsageRecord per `turns` row with model
/// = `agent_name` from the session (e.g. "GitHub Copilot Chat"), requestCount=1,
/// outputTokens=0. The UI surfaces these as "blind interactions" (no token data).
public final class VSCodeChatReader {
    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Code/User/globalStorage/github.copilot-chat/session-store.db"
    }

    public let path: String

    public init(path: String = VSCodeChatReader.defaultPath) {
        self.path = path
    }

    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Returns the set of session IDs known to VS Code (used to classify
    /// events.jsonl sessions as CLI vs VS Code agent).
    public func knownSessionIds() throws -> Set<String> {
        guard fileExists else { return [] }
        var ids: Set<String> = []
        let db = try SQLite(path: path, readOnly: true)
        try db.query("SELECT id FROM sessions") { row in
            if let id = row.string(0) { ids.insert(id) }
        }
        return ids
    }

    /// Emits a UsageRecord per `turns` row for sessions where `agent_name` is
    /// either NULL or "GitHub Copilot Chat" (i.e. ask/edit mode where no
    /// events.jsonl exists). Sessions running `copilotcli` agent are skipped here
    /// because they're already covered by events.jsonl parsing.
    public func chatInteractions(since: Date? = nil) throws -> [UsageRecord] {
        guard fileExists else { return [] }
        let db = try SQLite(path: path, readOnly: true)
        var rows: [UsageRecord] = []

        // We only count sessions whose agent_name is not the agent-mode marker.
        // Empirically observed values: "GitHub Copilot Chat", "Explore", "claude",
        // "copilotcli", "Meta Agentic Project Scaffold", "unknown", NULL.
        // "copilotcli" writes events.jsonl, so skip it here to avoid double counting.
        // Note: we intentionally do NOT SELECT t.user_message, only filter on it,
        // so the prompt text never enters this process's memory.
        let sql = """
            SELECT s.id, COALESCE(s.agent_name, 'GitHub Copilot Chat') AS agent,
                   t.timestamp
              FROM sessions s
              JOIN turns t ON s.id = t.session_id
             WHERE COALESCE(s.host_type, '') = 'vscode'
               AND COALESCE(s.agent_name, '') != 'copilotcli'
               AND t.user_message IS NOT NULL
               AND length(t.user_message) > 0
        """
        try db.query(sql) { row in
            guard let sessionId = row.string(0) else { return }
            let agent = row.string(1) ?? "GitHub Copilot Chat"
            let tsString = row.string(2) ?? ""
            guard let ts = Self.parseTimestamp(tsString) else { return }
            if let since, ts < since { return }
            let rec = UsageRecord(
                timestamp: ts,
                sessionId: sessionId,
                messageId: nil,
                source: .vscodeChat,
                model: agent,
                outputTokens: 0,
                inputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                requestCount: 1,
                premiumCost: nil
            )
            rows.append(rec)
        }
        return rows
    }

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

    private static func parseTimestamp(_ s: String) -> Date? {
        if let d = iso8601Frac.date(from: s) { return d }
        return iso8601.date(from: s)
    }
}
