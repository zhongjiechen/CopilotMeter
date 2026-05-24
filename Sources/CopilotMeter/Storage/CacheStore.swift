import Foundation

/// Local SQLite cache that stores parsed UsageRecords plus per-file resume
/// offsets so we never re-parse the same event twice.
///
/// Stored under `~/Library/Application Support/CopilotMeter/cache.db`.
public final class CacheStore {
    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Application Support/CopilotMeter"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/cache.db"
    }

    private let db: SQLite

    public init(path: String = CacheStore.defaultPath) throws {
        self.db = try SQLite(path: path, readOnly: false)
        try initSchema()
    }

    private func initSchema() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS file_state (
                file_path  TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                byte_offset INTEGER NOT NULL DEFAULT 0,
                session_ended INTEGER NOT NULL DEFAULT 0,
                last_event_at REAL,
                updated_at REAL NOT NULL
            );
        """)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                session_id TEXT NOT NULL,
                message_id TEXT,
                source TEXT NOT NULL,
                model TEXT NOT NULL,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_write INTEGER NOT NULL DEFAULT 0,
                request_count REAL NOT NULL DEFAULT 0,
                premium_cost REAL,
                kind TEXT NOT NULL,  -- 'msg' or 'shutdown' or 'chat'
                UNIQUE(session_id, message_id, kind, model)
            );
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS idx_records_ts ON records(ts);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_records_source ON records(source);")

        // Migration: add remote_name column to records and file_state.
        // SQLite's ALTER TABLE ADD COLUMN is idempotent if we guard on table_info.
        try migrate(table: "records", addColumn: "remote_name", typeDecl: "TEXT")
        try migrate(table: "file_state", addColumn: "remote_name", typeDecl: "TEXT")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_records_remote ON records(remote_name);")

        // Migration: ai_credits_nano column (nano-AIU; 1 AIU = 10^9 nano = $0.01).
        // Stored as INTEGER (Int64); NULL when the source CLI version didn't
        // emit totalNanoAiu so the aggregator can decide whether to fall back
        // to a token-based estimate.
        try migrate(table: "records", addColumn: "ai_credits_nano", typeDecl: "INTEGER")

        try db.exec("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                key TEXT PRIMARY KEY,
                value TEXT
            );
        """)
        try migrationV016SplitTranscriptAgent()
    }

    /// v0.1.6 migration: PR #11 ingested every transcript user.message as
    /// `.vscodeChat`. PR #12 introduced the Agent-vs-Ask distinction. This
    /// migration wipes the **transcript-derived** records (identified by the
    /// hardcoded `model = "GitHub Copilot Chat"`) and resets the per-file
    /// byte offsets so the next refresh re-ingests them with the new
    /// classification. Token data (events.jsonl `.vscodeAgent` rows with
    /// real model names like `claude-opus-4.7-…`) is unaffected.
    private func migrationV016SplitTranscriptAgent() throws {
        var already = false
        try db.query("SELECT value FROM schema_meta WHERE key = ?",
                     bindings: ["v016_split_transcript_agent_v2"]) { row in
            already = (row.string(0) ?? "") == "done"
        }
        if already { return }

        // Delete only transcript-derived chat/agent rows. The
        // model="GitHub Copilot Chat" filter excludes events.jsonl-derived
        // rows (those have real model names).
        try db.execute("""
            DELETE FROM records
             WHERE source IN (?, ?) AND kind = ? AND model = ?
        """, bindings: [
            UsageRecord.Source.vscodeChat.rawValue,
            UsageRecord.Source.vscodeAgent.rawValue,
            RecordKind.message.rawValue,
            "GitHub Copilot Chat",
        ])
        // Reset byte-offsets for local transcript files so the reader
        // re-scans them from byte 0. Remote offsets are handled separately
        // in UsageRefresher (we delete the per-host offsets.json file).
        try db.execute(
            "DELETE FROM file_state WHERE file_path LIKE '%/GitHub.copilot-chat/transcripts/%'"
        )
        // Recovery for the first iteration of this migration which wiped
        // events.jsonl-derived rows too: reset their file_state byte
        // offsets so the next refresh repopulates them (INSERT OR IGNORE
        // dedups so this is safe for installs that didn't hit the bug).
        try db.execute(
            "DELETE FROM file_state WHERE file_path LIKE '%/.copilot/session-state/%'"
        )
        try db.execute(
            "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
            bindings: ["v016_split_transcript_agent_v2", "done"]
        )
    }

    /// Returns true iff the named migration has been recorded as done.
    /// Used by `UsageRefresher` to also wipe out remote `offsets.json`
    /// caches on the same one-shot upgrade path.
    public func migrationDone(_ key: String) -> Bool {
        var done = false
        try? db.query("SELECT value FROM schema_meta WHERE key = ?", bindings: [key]) { row in
            done = (row.string(0) ?? "") == "done"
        }
        return done
    }
    public func markMigrationDone(_ key: String) {
        try? db.execute(
            "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
            bindings: [key, "done"]
        )
    }

    private func migrate(table: String, addColumn col: String, typeDecl: String) throws {
        var hasColumn = false
        try db.query("PRAGMA table_info(\(table))") { row in
            if row.string(1) == col { hasColumn = true }
        }
        if !hasColumn {
            try db.exec("ALTER TABLE \(table) ADD COLUMN \(col) \(typeDecl)")
        }
    }

    public struct FileState {
        public let filePath: String
        public let byteOffset: Int64
        public let sessionEnded: Bool
        public let lastEventAt: Date?
    }

    public func fileState(filePath: String) throws -> FileState? {
        var out: FileState?
        try db.query(
            "SELECT byte_offset, session_ended, last_event_at FROM file_state WHERE file_path = ?",
            bindings: [filePath]
        ) { row in
            let offset = row.int64(0)
            let ended = row.int(1) != 0
            let ts = row.isNull(2) ? nil : Date(timeIntervalSince1970: row.double(2))
            out = FileState(filePath: filePath, byteOffset: offset, sessionEnded: ended, lastEventAt: ts)
        }
        return out
    }

    public func updateFileState(
        filePath: String,
        sessionId: String,
        byteOffset: Int64,
        sessionEnded: Bool,
        lastEventAt: Date?
    ) throws {
        try db.execute("""
            INSERT INTO file_state (file_path, session_id, byte_offset, session_ended, last_event_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                byte_offset = excluded.byte_offset,
                session_ended = excluded.session_ended,
                last_event_at = excluded.last_event_at,
                updated_at = excluded.updated_at
        """, bindings: [
            filePath,
            sessionId,
            Int(byteOffset),
            sessionEnded ? 1 : 0,
            lastEventAt?.timeIntervalSince1970,
            Date().timeIntervalSince1970
        ])
    }

    /// Distinguishes "msg" (per-message), "shutdown" (session totals) and "chat" rows
    /// for de-dup purposes (UNIQUE on (session_id, message_id, kind, model)).
    public enum RecordKind: String {
        case message = "msg"
        case shutdown = "shutdown"
        case chat = "chat"
    }

    public func insertRecord(_ r: UsageRecord, kind: RecordKind) throws {
        // INSERT OR IGNORE so re-parsing the same lines is a no-op.
        // UNIQUE constraint deliberately does NOT include remote_name — a
        // record's identity is (session, message, kind, model) on whichever
        // host produced it. Two remotes don't naturally share session IDs.
        try db.execute("""
            INSERT OR IGNORE INTO records
            (ts, session_id, message_id, source, model, output_tokens, input_tokens,
             cache_read, cache_write, request_count, premium_cost, kind, remote_name,
             ai_credits_nano)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            r.timestamp.timeIntervalSince1970,
            r.sessionId,
            r.messageId,
            r.source.rawValue,
            r.model,
            r.outputTokens,
            r.inputTokens,
            r.cacheReadTokens,
            r.cacheWriteTokens,
            r.requestCount,
            r.premiumCost,
            kind.rawValue,
            r.remoteName,
            r.aiCreditsNano,
        ])

        // If the row already existed (e.g. inserted by an older build that
        // didn't know about AIU) and we now have an authoritative AIU value,
        // backfill it. Bounded UPDATE matches at most one row via the UNIQUE
        // index and only writes when the existing column is NULL or smaller.
        if let aiu = r.aiCreditsNano, aiu > 0 {
            try db.execute("""
                UPDATE records
                   SET ai_credits_nano = ?
                 WHERE session_id = ?
                   AND IFNULL(message_id, '') = IFNULL(?, '')
                   AND kind = ?
                   AND model = ?
                   AND (ai_credits_nano IS NULL OR ai_credits_nano < ?)
            """, bindings: [
                aiu, r.sessionId, r.messageId, kind.rawValue, r.model, aiu,
            ])
        }
    }

    /// Drop all chat rows so we can re-derive them from the source-of-truth VS Code
    /// DB on each refresh (cheaper than tracking incremental state for a small table).
    /// `remoteName == nil` clears only local; pass a specific name to clear that
    /// remote's chat rows; pass an empty array to clear nothing extra.
    public func clearChatRecords(remoteName: String? = nil) throws {
        if let name = remoteName {
            try db.execute(
                "DELETE FROM records WHERE kind = ? AND remote_name = ?",
                bindings: [RecordKind.chat.rawValue, name]
            )
        } else {
            try db.execute(
                "DELETE FROM records WHERE kind = ? AND remote_name IS NULL",
                bindings: [RecordKind.chat.rawValue]
            )
        }
    }

    /// Per-session count of records that came from VS Code Chat workspace
    /// transcripts (source=vscodeChat OR vscodeAgent, kind=msg). Used to
    /// de-dup against the central `session-store.db` so we don't double-count
    /// overlapping sessions: when the transcripts have ≥ as many turns for a
    /// session as the central DB, we skip the DB rows for that session.
    public func chatTranscriptSessionCounts(remoteName: String?) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let sql: String
        let bindings: [Any?]
        if let name = remoteName {
            sql = """
                SELECT session_id, COUNT(*) FROM records
                 WHERE source IN (?, ?) AND kind = ? AND remote_name = ?
                 GROUP BY session_id
            """
            bindings = [
                UsageRecord.Source.vscodeChat.rawValue,
                UsageRecord.Source.vscodeAgent.rawValue,
                RecordKind.message.rawValue,
                name,
            ]
        } else {
            sql = """
                SELECT session_id, COUNT(*) FROM records
                 WHERE source IN (?, ?) AND kind = ? AND remote_name IS NULL
                 GROUP BY session_id
            """
            bindings = [
                UsageRecord.Source.vscodeChat.rawValue,
                UsageRecord.Source.vscodeAgent.rawValue,
                RecordKind.message.rawValue,
            ]
        }
        try db.query(sql, bindings: bindings) { row in
            if let sid = row.string(0) {
                out[sid] = row.int(1)
            }
        }
        return out
    }

    /// Reclassifies VS Code Chat workspace-transcript rows for the given
    /// session ids from `.vscodeChat` to `.vscodeAgent`. Used when the
    /// extractor sees a `tool.execution_start` for a session it previously
    /// ingested as plain Chat. `remoteName == nil` scopes to local rows;
    /// otherwise scopes to the given remote.
    public func reclassifyTranscriptChatAsAgent(sessionIds: Set<String>, remoteName: String?) throws {
        guard !sessionIds.isEmpty else { return }
        // SQLite has no native array binding — build a placeholder list.
        let placeholders = Array(repeating: "?", count: sessionIds.count).joined(separator: ",")
        var bindings: [Any?] = [
            UsageRecord.Source.vscodeAgent.rawValue,
            UsageRecord.Source.vscodeChat.rawValue,
            RecordKind.message.rawValue,
        ]
        bindings.append(contentsOf: sessionIds.map { $0 as Any })
        if let name = remoteName {
            let sql = """
                UPDATE records SET source = ?
                 WHERE source = ? AND kind = ? AND remote_name = ?
                   AND session_id IN (\(placeholders))
            """
            bindings.insert(name, at: 3)
            try db.execute(sql, bindings: bindings)
        } else {
            let sql = """
                UPDATE records SET source = ?
                 WHERE source = ? AND kind = ? AND remote_name IS NULL
                   AND session_id IN (\(placeholders))
            """
            try db.execute(sql, bindings: bindings)
        }
    }

    /// Retroactively fills in the model column for records that came in with
    /// `model="unknown"` because the per-message event didn't include `model`
    /// and we hadn't yet observed the session.start (e.g., older CLI builds,
    /// or a sync that resumed past offset 0). Scoped to message-kind rows so
    /// shutdown-roll-up rows (which already have a model from `modelMetrics`)
    /// are untouched.
    public func backfillUnknownModel(sessionId: String, remoteName: String?, model: String) throws {
        guard !model.isEmpty, model != "unknown" else { return }
        if let name = remoteName {
            try db.execute(
                """
                UPDATE records SET model = ?
                 WHERE session_id = ? AND remote_name = ?
                   AND kind = ? AND model = 'unknown'
                """,
                bindings: [model, sessionId, name, RecordKind.message.rawValue]
            )
        } else {
            try db.execute(
                """
                UPDATE records SET model = ?
                 WHERE session_id = ? AND remote_name IS NULL
                   AND kind = ? AND model = 'unknown'
                """,
                bindings: [model, sessionId, RecordKind.message.rawValue]
            )
        }
    }

    /// Updates the `ai_credits_nano` column on an existing shutdown row.
    /// Used both during fresh ingestion (no-op if already set to same value)
    /// and for one-shot back-fills after upgrading from a pre-AIU build.
    /// Only overwrites NULL or smaller values to stay idempotent.
    public func setAiCreditsNano(sessionId: String, remoteName: String?, model: String, nano: Int64) throws {
        guard nano > 0 else { return }
        if let name = remoteName {
            try db.execute(
                """
                UPDATE records SET ai_credits_nano = ?
                 WHERE session_id = ? AND remote_name = ?
                   AND model = ? AND kind = ?
                   AND (ai_credits_nano IS NULL OR ai_credits_nano < ?)
                """,
                bindings: [nano, sessionId, name, model, RecordKind.shutdown.rawValue, nano]
            )
        } else {
            try db.execute(
                """
                UPDATE records SET ai_credits_nano = ?
                 WHERE session_id = ? AND remote_name IS NULL
                   AND model = ? AND kind = ?
                   AND (ai_credits_nano IS NULL OR ai_credits_nano < ?)
                """,
                bindings: [nano, sessionId, model, RecordKind.shutdown.rawValue, nano]
            )
        }
    }

    /// Returns session_ids of local (remote_name IS NULL) shutdown rows that
    /// don't yet have `ai_credits_nano` set. Used by the one-shot AIU
    /// back-fill on app start when upgrading from a pre-AIU build.
    public func localShutdownSessionsMissingAiu() throws -> [String] {
        var ids: [String] = []
        try db.query(
            """
            SELECT DISTINCT session_id FROM records
             WHERE remote_name IS NULL
               AND kind = ?
               AND ai_credits_nano IS NULL
            """,
            bindings: [RecordKind.shutdown.rawValue]
        ) { row in
            if let sid = row.string(0) { ids.append(sid) }
        }
        return ids
    }

    public func allRecords(since: Date? = nil) throws -> [UsageRecord] {
        var rows: [UsageRecord] = []
        let sql: String
        let bindings: [Any?]
        if let since {
            sql = """
                SELECT ts, session_id, message_id, source, model,
                       output_tokens, input_tokens, cache_read, cache_write,
                       request_count, premium_cost, remote_name, ai_credits_nano
                  FROM records WHERE ts >= ?
            """
            bindings = [since.timeIntervalSince1970]
        } else {
            sql = """
                SELECT ts, session_id, message_id, source, model,
                       output_tokens, input_tokens, cache_read, cache_write,
                       request_count, premium_cost, remote_name, ai_credits_nano
                  FROM records
            """
            bindings = []
        }
        try db.query(sql, bindings: bindings) { row in
            let ts = Date(timeIntervalSince1970: row.double(0))
            let sessionId = row.string(1) ?? ""
            let messageId = row.string(2)
            let source = UsageRecord.Source(rawValue: row.string(3) ?? "") ?? .unknown
            let model = row.string(4) ?? "unknown"
            let cost: Double? = row.isNull(10) ? nil : row.double(10)
            let remote: String? = row.isNull(11) ? nil : row.string(11)
            let aiuNano: Int64? = row.isNull(12) ? nil : row.int64(12)
            rows.append(UsageRecord(
                timestamp: ts,
                sessionId: sessionId,
                messageId: messageId,
                source: source,
                model: model,
                outputTokens: row.int(5),
                inputTokens: row.int(6),
                cacheReadTokens: row.int(7),
                cacheWriteTokens: row.int(8),
                requestCount: row.double(9),
                premiumCost: cost,
                aiCreditsNano: aiuNano,
                remoteName: remote
            ))
        }
        return rows
    }

    public func recordCount() throws -> Int {
        var n = 0
        try db.query("SELECT COUNT(*) FROM records") { row in n = row.int(0) }
        return n
    }
}
