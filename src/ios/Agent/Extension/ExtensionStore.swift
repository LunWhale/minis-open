import Foundation
import SQLite3

// MARK: - Extension Store

/// SQLite-backed registry for installed extensions. Tracks id, manifest,
/// enabled state, and installed location. Extensions unpack to
/// `Library/MinisChat/extensions/<id>/`; the DB holds metadata + enable
/// flags (mirrors the SkillStore pattern).
actor ExtensionStore {
    static let shared = ExtensionStore()

    private var db: OpaquePointer?
    private let dbURL: URL
    /// Host directory where extension bundles are unpacked.
    let extensionsDir: URL

    struct Record: Identifiable, Sendable {
        let id: String
        let name: String
        let version: String
        let kinds: [String]
        let permissions: [String]
        let enabled: Bool
        let installedAt: Date
        /// Absolute URL of the unpacked bundle root.
        let bundleURL: URL
    }

    private init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let base = library.appendingPathComponent("MinisChat", isDirectory: true)
        self.dbURL = base.appendingPathComponent("extensions.db")
        self.extensionsDir = base.appendingPathComponent("extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        openDatabase()
        createTables()
    }

    private func openDatabase() {
        let rc = sqlite3_open(dbURL.path, &db)
        if rc != SQLITE_OK {
            AppLogger(category: "ExtensionStore").error("Failed to open extensions.db: \(rc)")
        }
        exec("PRAGMA journal_mode=WAL")
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS extensions (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                version     TEXT NOT NULL,
                kinds_json  TEXT NOT NULL,
                permissions_json TEXT NOT NULL,
                enabled     INTEGER NOT NULL DEFAULT 1,
                installed_at REAL NOT NULL
            )
        """)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            AppLogger(category: "ExtensionStore").error("SQL: \(String(cString: err ?? "?"))")
            sqlite3_free(err)
            return false
        }
        return true
    }

    // MARK: - CRUD

    /// Register an installed (already-unpacked) extension.
    func register(manifest: ExtensionManifest, enabled: Bool = true) throws {
        // Reject duplicate ids unless version differs (upgrade path: call
        // update() instead).
        if let existing = try? get(id: manifest.id), existing.version == manifest.version {
            throw ExtensionError.duplicateID(manifest.id)
        }
        let kinds = try JSONEncoder().encode(manifest.kinds)
        let perms = try JSONEncoder().encode(manifest.permissions)
        let sql = """
            INSERT OR REPLACE INTO extensions (id, name, version, kinds_json, permissions_json, enabled, installed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ExtensionError.runtime("prepare failed") }
        sqlite3_bind_text(stmt, 1, (manifest.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (manifest.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (manifest.version as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, (String(data: kinds, encoding: .utf8)! as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, (String(data: perms, encoding: .utf8)! as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 6, enabled ? 1 : 0)
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { throw ExtensionError.runtime("insert failed") }
    }

    func list() -> [Record] {
        var out: [Record] = []
        let sql = "SELECT id, name, version, kinds_json, permissions_json, enabled, installed_at FROM extensions ORDER BY name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let version = String(cString: sqlite3_column_text(stmt, 2))
            let kindsJSON = String(cString: sqlite3_column_text(stmt, 3))
            let permsJSON = String(cString: sqlite3_column_text(stmt, 4))
            let enabled = sqlite3_column_int(stmt, 5) == 1
            let installedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let kinds = (try? JSONDecoder().decode([String].self, from: Data(kindsJSON.utf8))) ?? []
            let perms = (try? JSONDecoder().decode([String].self, from: Data(permsJSON.utf8))) ?? []
            let bundle = extensionsDir.appendingPathComponent(id, isDirectory: true)
            out.append(Record(id: id, name: name, version: version, kinds: kinds, permissions: perms, enabled: enabled, installedAt: installedAt, bundleURL: bundle))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func get(id: String) throws -> Record? {
        list().first { $0.id == id }
    }

    func setEnabled(id: String, enabled: Bool) throws {
        let sql = "UPDATE extensions SET enabled = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ExtensionError.notFound(id) }
        sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func uninstall(id: String) throws {
        let sql = "DELETE FROM extensions WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ExtensionError.notFound(id) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        // Remove bundle dir.
        try? FileManager.default.removeItem(at: extensionsDir.appendingPathComponent(id, isDirectory: true))
    }

    /// Path of a bundled asset within an extension.
    func assetURL(id: String, relativePath: String) -> URL {
        extensionsDir.appendingPathComponent(id, isDirectory: true).appendingPathComponent(relativePath)
    }
}
