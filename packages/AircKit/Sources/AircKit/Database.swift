// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

/// A minimal wrapper around the system SQLite3 library.
final class Database {
    enum DBError: Error, CustomStringConvertible {
        case open(String), prepare(String, String), step(String)
        var description: String {
            switch self {
            case .open(let m): "open: \(m)"
            case .prepare(let sql, let m): "prepare \(sql): \(m)"
            case .step(let m): "step: \(m)"
            }
        }
    }

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// `path == nil` opens an in-memory database (tests).
    init(path: String?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path ?? ":memory:", &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DBError.open(msg)
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=OFF")
    }

    deinit {
        for s in statements.values { sqlite3_finalize(s) }
        sqlite3_close(db)
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw DBError.step(msg)
        }
    }

    enum Value {
        case text(String), real(Double), int(Int64), null
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = statements[sql] {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            return s
        }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw DBError.prepare(sql, errorMessage)
        }
        statements[sql] = s
        return s
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ s: OpaquePointer, _ values: [Value]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let t): sqlite3_bind_text(s, idx, t, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(s, idx, d)
            case .int(let n): sqlite3_bind_int64(s, idx, n)
            case .null: sqlite3_bind_null(s, idx)
            }
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let s = try statement(sql)
        bind(s, values)
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.step(errorMessage) }
        sqlite3_reset(s)
    }

    /// Runs a query and returns each row's columns as strings, doubles or nil.
    func query(_ sql: String, _ values: [Value] = []) throws -> [[Any?]] {
        let s = try statement(sql)
        bind(s, values)
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.step(errorMessage) }
            var row: [Any?] = []
            for c in 0..<sqlite3_column_count(s) {
                switch sqlite3_column_type(s, c) {
                case SQLITE_NULL: row.append(nil)
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(s, c))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(s, c))
                // L3: an empty text or BLOB value comes back as a NULL pointer.
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(s, c))
                    row.append(sqlite3_column_blob(s, c).map { Data(bytes: $0, count: n) } ?? Data())
                default: row.append(sqlite3_column_text(s, c).map { String(cString: $0) } ?? "")
                }
            }
            rows.append(row)
        }
        sqlite3_reset(s)
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
