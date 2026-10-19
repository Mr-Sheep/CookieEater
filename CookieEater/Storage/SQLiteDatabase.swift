import Foundation
import SQLite3

struct SQLiteError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// A thin wrapper around the system SQLite library. Use each instance from one thread only.
final class SQLiteDatabase {
    struct Row {
        fileprivate let statement: OpaquePointer

        func int64(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
        }

        func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: text)
        }

        func data(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }

        func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }
    }

    enum Mode {
        case readWrite
        case readOnly
        /// Read-only and without locks, for a database nothing writes to while it's open.
        case immutable
    }

    let url: URL
    private let handle: OpaquePointer

    init(url: URL, mode: Mode = .readWrite) throws {
        var db: OpaquePointer?
        let (name, flags) = switch mode {
        case .readWrite: (url.path(percentEncoded: false), SQLITE_OPEN_READWRITE)
        case .readOnly: (url.path(percentEncoded: false), SQLITE_OPEN_READONLY)
        // SQLite expects a URI to be percent-encoded, as `absoluteString` is.
        case .immutable: (url.absoluteString + "?immutable=1", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
        }
        let status = sqlite3_open_v2(name, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            sqlite3_close(db)
            throw SQLiteError(message: "Couldn't open \(url.lastPathComponent): \(reason)")
        }
        self.url = url
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(message)
            throw SQLiteError(message: "\(url.lastPathComponent): \(reason)")
        }
    }

    func forEachRow(_ sql: String, _ body: (Row) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try step(statement, body)
    }

    /// Like `forEachRow(_:_:)`, with `value` bound to the statement's single parameter.
    func forEachRow(_ sql: String, binding value: Int64, _ body: (Row) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, value)
        try step(statement, body)
    }

    func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try forEachRow(sql) { value = Int($0.int64(0)) }
        return value
    }

    /// Runs `sql` once for each value, bound to its single parameter.
    func run(_ sql: String, binding values: [Int64]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for value in values {
            sqlite3_bind_int64(statement, 1, value)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError }
            sqlite3_reset(statement)
        }
    }

    func run(_ sql: String, binding values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for value in values {
            sqlite3_bind_text(statement, 1, value, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError }
            sqlite3_reset(statement)
        }
    }

    /// Deletes the rows whose `column` is in `subquery`. Does nothing if the table or column doesn't exist,
    /// since browsers add and drop tables between versions.
    func deleteRows(from table: String, where column: String, in subquery: String) throws {
        guard try tableExists(table), try columns(of: table).contains(column) else { return }
        try execute("DELETE FROM \(table) WHERE \(column) IN (\(subquery))")
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func tableExists(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try forEachRow("PRAGMA table_info(\"\(table)\")") { names.insert($0.string(1)) }
        return names
    }

    private func step(_ statement: OpaquePointer, _ body: (Row) throws -> Void) throws {
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw lastError
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError
        }
        return statement
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private var lastError: SQLiteError {
        SQLiteError(message: "\(url.lastPathComponent): \(lastErrorMessage)")
    }
}
