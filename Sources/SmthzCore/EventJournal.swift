import Foundation
import SQLite3

public struct JournalEntry: Sendable, Equatable {
    public let fingerprint: String?
    public let sequence: Int64
    public let requestID: String
    public let kind: String
    public let payload: Data
}

public enum JournalError: Error {
    case openFailed(String)
    case statementFailed(String)
}

public final class EventJournal: @unchecked Sendable {
    public let path: String
    private var db: OpaquePointer?

    public init(path: String) throws {
        self.path = path
        if sqlite3_open(path, &db) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw JournalError.openFailed(message)
        }
        for sql in ["PRAGMA journal_mode=WAL;", "CREATE TABLE IF NOT EXISTS rpc_requests (request_id TEXT PRIMARY KEY, method TEXT NOT NULL, params_hash TEXT NOT NULL)", "CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, payload BLOB NOT NULL)"] {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                sqlite3_close(db)
                throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(events)", -1, &columns, nil) == SQLITE_OK else {
            throw JournalError.statementFailed("cannot inspect journal schema")
        }
        var hasFingerprint = false
        while sqlite3_step(columns) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(columns, 1)) == "fingerprint" { hasFingerprint = true }
        }
        sqlite3_finalize(columns)
        if !hasFingerprint, sqlite3_exec(db, "ALTER TABLE events ADD COLUMN fingerprint TEXT", nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            db = nil
            throw JournalError.statementFailed(message)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    public func append(requestID: String, kind: String, payload: Data, fingerprint: String? = nil) throws -> Int64 {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let sql = "INSERT OR IGNORE INTO events(request_id, kind, payload, fingerprint) VALUES(?, ?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, requestID, -1, transient)
        sqlite3_bind_text(stmt, 2, kind, -1, transient)
        payload.withUnsafeBytes {
            sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(payload.count), transient)
        }

        if let fingerprint { sqlite3_bind_text(stmt, 4, fingerprint, -1, transient) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }

        let select = "SELECT sequence FROM events WHERE request_id = ?;"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, select, -1, &selectStmt, nil) != SQLITE_OK {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(selectStmt) }

        sqlite3_bind_text(selectStmt, 1, requestID, -1, transient)
        if sqlite3_step(selectStmt) == SQLITE_ROW {
            return sqlite3_column_int64(selectStmt, 0)
        }
        throw JournalError.statementFailed("missing row")
    }

    /// Used under the host's journal lock, together with response lookup.
    public func matchesRequest(requestID: String, method: String, paramsHash: String) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT method, params_hash FROM rpc_requests WHERE request_id = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, requestID, -1, transient)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            return String(cString: sqlite3_column_text(stmt, 0)) == method &&
                String(cString: sqlite3_column_text(stmt, 1)) == paramsHash
        case SQLITE_DONE: return false // Legacy responses have no safe binding.
        default: throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Atomically commits the response and its retry identity, including across restart.
    public func appendResponse(requestID: String, method: String, paramsHash: String, payload: Data) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        _ = try append(requestID: requestID, kind: "response:\(method)", payload: payload)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO rpc_requests(request_id, method, params_hash) VALUES(?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, requestID, -1, transient)
        sqlite3_bind_text(stmt, 2, method, -1, transient)
        sqlite3_bind_text(stmt, 3, paramsHash, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE,
              sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        committed = true
    }

    public func entry(requestID: String) throws -> JournalEntry? {
        let sql = "SELECT sequence, request_id, kind, payload, fingerprint FROM events WHERE request_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, requestID, -1, transient) == SQLITE_OK else {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        switch sqlite3_step(stmt) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            let count = Int(sqlite3_column_bytes(stmt, 3))
            return JournalEntry(
                fingerprint: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                sequence: sqlite3_column_int64(stmt, 0),
                requestID: String(cString: sqlite3_column_text(stmt, 1)),
                kind: String(cString: sqlite3_column_text(stmt, 2)),
                payload: count == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, 3), count: count)
            )
        default:
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func read(after sequence: Int64, limit: Int) throws -> [JournalEntry] {
        let sql = "SELECT sequence, request_id, kind, payload, fingerprint FROM events WHERE sequence > ? ORDER BY sequence LIMIT ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw JournalError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sequence)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var entries = [JournalEntry]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = String(cString: sqlite3_column_text(stmt, 2))
            let n = Int(sqlite3_column_bytes(stmt, 3))
            let payload = n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, 3), count: n)
            entries.append(JournalEntry(
                fingerprint: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                sequence: sqlite3_column_int64(stmt, 0),
                requestID: String(cString: sqlite3_column_text(stmt, 1)),
                kind: kind,
                payload: payload
            ))
        }
        return entries
    }
}
