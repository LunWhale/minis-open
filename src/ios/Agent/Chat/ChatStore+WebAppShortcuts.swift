//
//  ChatStore+WebAppShortcuts.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, web-app shortcuts: list / get / save / delete.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")

extension ChatStore {
    // MARK: - WebApp Shortcuts

    /// All shortcuts, newest first. Inlined here (rather than in a sibling
    /// file) so it can read the actor-private `db` and `bindOptionalText`
    /// helpers without widening their visibility.
    func listWebAppShortcuts() -> [WebAppShortcut] {
        let sql = """
            SELECT id, html_path, path_scope, scope_context, title,
                   icon_ref, icon_cache_path, created_at, source_session_id
              FROM webapp_shortcuts
             ORDER BY created_at DESC
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [WebAppShortcut] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = decodeWebAppShortcutRow(stmt) {
                out.append(row)
            }
        }
        return out
    }

    /// Lookup by id. Returns nil if the row was removed (manually deleted
    /// in-app or pruned because the source session no longer exists).
    func webAppShortcut(id: String) -> WebAppShortcut? {
        let sql = """
            SELECT id, html_path, path_scope, scope_context, title,
                   icon_ref, icon_cache_path, created_at, source_session_id
              FROM webapp_shortcuts
             WHERE id = ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeWebAppShortcutRow(stmt)
    }

    /// Insert or replace by id. Last-write-wins semantics — the home-screen
    /// tile only references id so this is the safe operation. Old icon
    /// bitmaps at a previous `iconCachePath` should be cleaned up by the
    /// caller before invoking this; the row simply records the new pointer.
    func saveWebAppShortcut(_ shortcut: WebAppShortcut) {
        let sql = """
            INSERT OR REPLACE INTO webapp_shortcuts
                (id, html_path, path_scope, scope_context, title,
                 icon_ref, icon_cache_path, created_at, source_session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("saveWebAppShortcut prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_bind_text(stmt, 1, (shortcut.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (shortcut.htmlPath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (shortcut.pathScope.rawValue as NSString).utf8String, -1, nil)
        bindOptionalText(stmt, index: 4, value: shortcut.scopeContext)
        sqlite3_bind_text(stmt, 5, (shortcut.title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (shortcut.iconRef.encoded as NSString).utf8String, -1, nil)
        bindOptionalText(stmt, index: 7, value: shortcut.iconCachePath)
        sqlite3_bind_double(stmt, 8, shortcut.createdAt.timeIntervalSince1970)
        bindOptionalText(stmt, index: 9, value: shortcut.sourceSessionId)
        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("saveWebAppShortcut step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Delete by id. Caller is responsible for removing any cached icon
    /// bitmap from `Library/WebAppIconCache/`.
    func deleteWebAppShortcut(id: String) {
        let sql = "DELETE FROM webapp_shortcuts WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        _ = sqlite3_step(stmt)
    }

    private func decodeWebAppShortcutRow(_ stmt: OpaquePointer?) -> WebAppShortcut? {
        guard let stmt else { return nil }
        guard let cId = sqlite3_column_text(stmt, 0),
              let cHtml = sqlite3_column_text(stmt, 1),
              let cScope = sqlite3_column_text(stmt, 2),
              let cTitle = sqlite3_column_text(stmt, 4),
              let cIcon = sqlite3_column_text(stmt, 5)
        else { return nil }
        let scopeStr = String(cString: cScope)
        guard let scope = WebAppPathScope(rawValue: scopeStr) else {
            logger.warning("decodeWebAppShortcutRow: unknown scope=\(scopeStr) — dropping")
            return nil
        }
        let scopeCtx = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let iconCache = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let srcSession = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        return WebAppShortcut(
            id: String(cString: cId),
            htmlPath: String(cString: cHtml),
            pathScope: scope,
            scopeContext: scopeCtx,
            title: String(cString: cTitle),
            iconRef: WebAppIconRef(encoded: String(cString: cIcon)),
            iconCachePath: iconCache,
            createdAt: createdAt,
            sourceSessionId: srcSession
        )
    }
}
