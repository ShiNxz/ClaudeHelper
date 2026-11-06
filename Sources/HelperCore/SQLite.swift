import Foundation
import SQLite3

let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDB {
    let handle: OpaquePointer

    init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let db { sqlite3_close_v2(db) }
            throw HelperError.message("Could not open \(path): \(msg)")
        }
        handle = db
        sqlite3_busy_timeout(db, 10_000)
    }

    deinit { sqlite3_close_v2(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw HelperError.message("SQLite: \(msg)")
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HelperError.message("SQLite prepare: \(errorMessage) in \(sql)")
        }
        return Statement(stmt, db: self)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

final class Statement {
    let stmt: OpaquePointer
    unowned let db: SQLiteDB

    init(_ stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ i: Int32, _ v: String?) -> Statement {
        if let v { sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT_PTR) } else { sqlite3_bind_null(stmt, i) }
        return self
    }

    @discardableResult
    func bind(_ i: Int32, _ v: Int64) -> Statement {
        sqlite3_bind_int64(stmt, i, v)
        return self
    }

    @discardableResult
    func bind(_ i: Int32, _ v: Double) -> Statement {
        sqlite3_bind_double(stmt, i, v)
        return self
    }

    /// Returns true while there is a row.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw HelperError.message("SQLite step: \(db.errorMessage)")
    }

    func run() throws {
        _ = try step()
        reset()
    }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func text(_ c: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, c) else { return nil }
        return String(cString: p)
    }

    func int64(_ c: Int32) -> Int64 { sqlite3_column_int64(stmt, c) }
    func double(_ c: Int32) -> Double { sqlite3_column_double(stmt, c) }
    func isNull(_ c: Int32) -> Bool { sqlite3_column_type(stmt, c) == SQLITE_NULL }
}
