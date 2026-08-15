import Foundation
import SQLite3

// MARK: - Todo Store

/// SQLite-backed store for session-scoped todo items.
///
/// Follows ChatStore's conventions: actor-isolated, WAL mode, idempotent
/// `CREATE TABLE IF NOT EXISTS`, timestamps stored as REAL (unix epoch).
/// Uses its own `todo.db` (not minis.db) so ChatStore's schema/migrations
/// stay untouched and todo data can evolve independently.
actor TodoStore {
    static let shared = TodoStore()
    private nonisolated static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?
    private let dbURL: URL

    private init() {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let baseURL = libraryURL.appendingPathComponent("MinisChat", isDirectory: true)
        self.dbURL = baseURL.appendingPathComponent("todo.db")

        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        openDatabase()
        createTables()
    }

    // MARK: - DB plumbing

    private func openDatabase() {
        let result = sqlite3_open(dbURL.path, &db)
        if result != SQLITE_OK {
            AppLogger(category: "TodoStore").error("Failed to open todo.db: \(result)")
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA foreign_keys=ON")
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS todos (
                id          TEXT PRIMARY KEY,
                session_id  TEXT NOT NULL,
                title       TEXT NOT NULL,
                detail      TEXT,
                status      TEXT NOT NULL DEFAULT 'pending',
                sort_order  INTEGER NOT NULL DEFAULT 0,
                parent_id   TEXT,
                created_at  REAL NOT NULL,
                updated_at  REAL NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_todos_session ON todos(session_id, sort_order)")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            AppLogger(category: "TodoStore").error("SQL error: \(errMsg.map { String(cString: $0) } ?? "?")")
            sqlite3_free(errMsg)
            return false
        }
        return true
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    // MARK: - CRUD

    /// Create one or more todos for a session. Returns created items.
    func create(sessionId: String, titles: [(title: String, detail: String?)]) -> [TodoItem] {
        guard !titles.isEmpty else { return [] }
        let nextOrder = (try? maxOrder(sessionId: sessionId)) ?? 0
        var created: [TodoItem] = []
        var order = nextOrder

        for t in titles {
            let item = TodoItem(
                sessionId: sessionId,
                title: t.title,
                detail: t.detail,
                order: order
            )
            order += 1

            let sql = """
                INSERT INTO todos (id, session_id, title, detail, status, sort_order, parent_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (item.title as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            if let d = item.detail {
                sqlite3_bind_text(stmt, 4, (d as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, (item.status.rawValue as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, Int32(item.order))
            if let p = item.parentId {
                sqlite3_bind_text(stmt, 7, (p as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, item.updatedAt.timeIntervalSince1970)

            if sqlite3_step(stmt) == SQLITE_DONE {
                created.append(item)
            }
            sqlite3_finalize(stmt)
        }
        return created
    }

    /// Update status / title / detail of an item. Returns the updated item or nil.
    func update(sessionId: String, id: String, status: TodoItem.Status?, title: String?, detail: String?) -> TodoItem? {
        guard let existing = get(sessionId: sessionId, id: id) else { return nil }
        let newStatus = status ?? existing.status
        let newTitle = title ?? existing.title
        let newDetail = detail ?? existing.detail

        let sql = """
            UPDATE todos SET title = ?, detail = ?, status = ?, updated_at = ?
            WHERE id = ? AND session_id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (newTitle as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        if let d = newDetail {
            sqlite3_bind_text(stmt, 2, (d as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, (newStatus.rawValue as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, now())
        sqlite3_bind_text(stmt, 5, (id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok ? get(sessionId: sessionId, id: id) : nil
    }

    /// List todos for a session, ordered by sort_order.
    func list(sessionId: String, statusFilter: TodoItem.Status? = nil) -> [TodoItem] {
        var items: [TodoItem] = []
        var sql = "SELECT id, session_id, title, detail, status, sort_order, parent_id, created_at, updated_at FROM todos WHERE session_id = ?"
        if let statusFilter {
            sql += " AND status = '\(statusFilter.rawValue)'"
        }
        sql += " ORDER BY sort_order ASC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(row(stmt))
        }
        sqlite3_finalize(stmt)
        return items
    }

    /// Delete a single todo (or all with a given status when `status` is set and `id` is nil).
    func delete(sessionId: String, id: String?, status: TodoItem.Status?) -> Int {
        var sql = "DELETE FROM todos WHERE session_id = ?"
        if let id {
            sql += " AND id = ?"
        } else if let status {
            sql += " AND status = ?"
        } else {
            return 0
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        if let id {
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        } else if let status {
            sqlite3_bind_text(stmt, 2, (status.rawValue as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        }
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE ? Int(sqlite3_changes(db)) : 0
    }

    // MARK: - Helpers

    private func get(sessionId: String, id: String) -> TodoItem? {
        let sql = "SELECT id, session_id, title, detail, status, sort_order, parent_id, created_at, updated_at FROM todos WHERE id = ? AND session_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        var item: TodoItem?
        if sqlite3_step(stmt) == SQLITE_ROW {
            item = row(stmt)
        }
        sqlite3_finalize(stmt)
        return item
    }

    private func maxOrder(sessionId: String) throws -> Int {
        let sql = "SELECT MAX(sort_order) FROM todos WHERE session_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        var maxVal: Int = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            maxVal = Int(sqlite3_column_int64(stmt, 0))
        }
        sqlite3_finalize(stmt)
        return maxVal
    }

    private func row(_ stmt: OpaquePointer?) -> TodoItem {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let sessionId = String(cString: sqlite3_column_text(stmt, 1))
        let title = String(cString: sqlite3_column_text(stmt, 2))
        var detail: String?
        if let c = sqlite3_column_text(stmt, 3) {
            detail = String(cString: c)
        }
        let statusRaw = String(cString: sqlite3_column_text(stmt, 4))
        let status = TodoItem.Status(rawValue: statusRaw) ?? .pending
        let order = Int(sqlite3_column_int(stmt, 5))
        var parentId: String?
        if let c = sqlite3_column_text(stmt, 6) {
            parentId = String(cString: c)
        }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        return TodoItem(
            id: id, sessionId: sessionId, title: title, detail: detail,
            status: status, order: order, parentId: parentId,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
