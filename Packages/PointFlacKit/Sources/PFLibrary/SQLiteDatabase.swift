import Foundation
import SQLite3

/// Why the library database failed.
public struct LibraryDatabaseError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// A value bound to, or read from, a statement.
enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// The smallest wrapper over the system SQLite3 that the library needs: open with WAL, explicit versioned migrations,
/// prepared statements and transactions.
///
/// Why not GRDB (the spec's expected choice): see the Plan 2 document. In short, a remote dependency could not be
/// resolved, noticed and cached safely overnight with five streams editing Package.swift, and this file is the only
/// one that would change.
///
/// Not thread-safe by design: one `SQLiteDatabase` belongs to one serial queue (the library's), which is what makes
/// it safe. The connection is opened `SQLITE_OPEN_NOMUTEX` for that reason.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// SQLite's "copy the bytes now" destructor, which Swift cannot import as a macro.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws(LibraryDatabaseError) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            handle = nil
            throw LibraryDatabaseError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    /// Runs one or more statements that return no rows.
    func execute(_ sql: String) throws(LibraryDatabaseError) {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw LibraryDatabaseError(code: status, message: message)
        }
    }

    /// Runs `sql` with `values` bound in order, and returns every row.
    @discardableResult
    func query(_ sql: String, _ values: [SQLValue] = []) throws(LibraryDatabaseError) -> [[SQLValue]] {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, index)
            case .integer(let v): status = sqlite3_bind_int64(statement, index, v)
            case .real(let v): status = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                // An explicit byte length, so an embedded NUL can never cut the text short.
                status = sqlite3_bind_text(statement, index, v, Int32(v.utf8.count), Self.transient)
            case .blob(let v):
                status = v.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
            guard status == SQLITE_OK else { throw failure(status) }
        }
        var rows: [[SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure(status) }
            let columns = sqlite3_column_count(statement)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(columns))
            for column in 0..<columns {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    let bytes = UnsafeBufferPointer(start: sqlite3_column_text(statement, column), count: count)
                    row.append(.text(String(decoding: bytes, as: UTF8.self)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), count > 0 {
                        row.append(.blob(Data(bytes: bytes, count: count)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs `body` in one transaction: committed when it returns, rolled back when it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The schema version (`PRAGMA user_version`).
    var userVersion: Int {
        if case .integer(let v) = (try? query("PRAGMA user_version"))?.first?.first { return Int(v) }
        return 0
    }

    /// Applies each migration after the stored version, in order, each in its own transaction with the version bump,
    /// so a crash mid-migration leaves the previous version intact. Never destructive: a database newer than this
    /// build is left untouched and refused.
    func migrate(_ migrations: [String]) throws {
        let current = userVersion
        guard current <= migrations.count else {
            throw LibraryDatabaseError(code: SQLITE_MISMATCH, message: "database version \(current) is newer")
        }
        for (offset, sql) in migrations.enumerated().dropFirst(current) {
            try transaction {
                try execute(sql)
                try execute("PRAGMA user_version = \(offset + 1)")
            }
        }
    }

    private func prepared(_ sql: String) throws(LibraryDatabaseError) -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard status == SQLITE_OK, let statement else { throw failure(status) }
        statements[sql] = statement
        return statement
    }

    private func failure(_ status: Int32) -> LibraryDatabaseError {
        LibraryDatabaseError(code: status, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "")
    }
}

extension SQLValue {
    var int: Int64? {
        if case .integer(let v) = self { return v }
        return nil
    }
    var double: Double? {
        switch self {
        case .real(let v): v
        case .integer(let v): Double(v)
        default: nil
        }
    }
    var string: String? {
        if case .text(let v) = self { return v }
        return nil
    }
    var data: Data? {
        if case .blob(let v) = self { return v }
        return nil
    }
    static func optional(_ value: Int?) -> SQLValue { value.map { .integer(Int64($0)) } ?? .null }
    static func optional(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
}
