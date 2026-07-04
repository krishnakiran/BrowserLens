import Foundation
import SQLite3

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = true) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            throw ImporterError.sqliteOpenFailed(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (SQLiteRow) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImporterError.sqliteQueryFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                try row(SQLiteRow(statement: statement))
            } else if result == SQLITE_DONE {
                return
            } else {
                throw ImporterError.sqliteQueryFailed(errorMessage)
            }
        }
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw ImporterError.sqliteQueryFailed(message)
        }
    }

    func statement(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImporterError.sqliteQueryFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ImporterError.sqliteQueryFailed(errorMessage)
        }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
    }
}

struct SQLiteRow {
    let statement: OpaquePointer?

    func string(_ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }
}

func sqliteBindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
    sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}
