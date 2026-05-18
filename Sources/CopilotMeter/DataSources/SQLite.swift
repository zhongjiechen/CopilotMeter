import Foundation
import SQLite3

/// Tiny ergonomic wrapper around the C SQLite API, sufficient for our read-only needs
/// against Copilot's session-store DBs and our own cache DB.
public final class SQLite {
    public enum SQLiteError: Error, CustomStringConvertible {
        case openFailed(String, Int32)
        case prepareFailed(String, Int32, String)
        case stepFailed(Int32, String)
        case execFailed(String, Int32, String)

        public var description: String {
            switch self {
            case .openFailed(let p, let c): return "SQLite open failed (\(c)) for \(p)"
            case .prepareFailed(let sql, let c, let msg): return "Prepare failed (\(c)): \(msg)\nSQL: \(sql)"
            case .stepFailed(let c, let msg): return "Step failed (\(c)): \(msg)"
            case .execFailed(let sql, let c, let msg): return "Exec failed (\(c)): \(msg)\nSQL: \(sql)"
            }
        }
    }

    private var db: OpaquePointer?
    public let path: String

    /// Opens the database in read-write mode by default. Use `readOnly: true` for
    /// safety when reading Copilot's own sqlite files (which may be locked).
    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var flags: Int32 = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        // Allow URI-style filename so we can append ?mode=ro&immutable=1 if needed
        flags |= SQLITE_OPEN_NOMUTEX
        // For read-only access to a DB another process is writing, the "immutable=1" hint
        // prevents trying to recover the WAL. Useful for Copilot's live DBs.
        let uri = readOnly ? "file:\(path)?mode=ro&immutable=1" : path
        if readOnly {
            flags |= SQLITE_OPEN_URI
        }
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            db = nil
            throw SQLiteError.openFailed("\(path): \(msg)", rc)
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "(no message)"
            if let err { sqlite3_free(err) }
            throw SQLiteError.execFailed(sql, rc, msg)
        }
    }

    /// Run a query and call `row` once per result. Bindings are positional and may be
    /// `Int`, `Int64`, `Double`, `String`, `Data`, or `nil`.
    public func query(
        _ sql: String,
        bindings: [Any?] = [],
        row: (Row) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(sql, rc, msg)
        }
        defer { sqlite3_finalize(stmt) }

        try bind(stmt: stmt, bindings: bindings)

        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                try row(Row(stmt: stmt!))
            } else if step == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.stepFailed(step, msg)
            }
        }
    }

    public func execute(_ sql: String, bindings: [Any?] = []) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(sql, rc, msg)
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt: stmt, bindings: bindings)
        let step = sqlite3_step(stmt)
        if step != SQLITE_DONE && step != SQLITE_ROW {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.stepFailed(step, msg)
        }
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(stmt: OpaquePointer?, bindings: [Any?]) throws {
        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .none:
                sqlite3_bind_null(stmt, idx)
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(stmt, idx, v)
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            case let v as String:
                sqlite3_bind_text(stmt, idx, v, -1, SQLite.SQLITE_TRANSIENT)
            case let v as Data:
                _ = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(v.count), SQLite.SQLITE_TRANSIENT)
                }
            case let v as Bool:
                sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            default:
                fatalError("Unsupported binding type for SQLite: \(type(of: value!))")
            }
        }
    }

    public struct Row {
        let stmt: OpaquePointer

        public func int(_ col: Int32) -> Int { Int(sqlite3_column_int64(stmt, col)) }
        public func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
        public func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
        public func string(_ col: Int32) -> String? {
            guard let cstr = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: cstr)
        }
        public func isNull(_ col: Int32) -> Bool {
            sqlite3_column_type(stmt, col) == SQLITE_NULL
        }
    }
}
